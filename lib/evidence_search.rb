# frozen_string_literal: true

# The model may request at most two scoped searches in its first decision.
# Ruby executes them and supplies bounded results to the single evidence call.
module EvidenceSearch
  STOP_WORDS = %w[the and for with this that from have has are was were not but can could does did how
                  what which when where please app issue report using after before into also would].freeze
  RELEASE_FIELDS = 'id tagName name description url publishedAt isDraft isPrerelease'
  RESOLVED_FIELDS = 'id number title body url closed closedAt stateReason'

  private

  def search_words(text)
    text.downcase.scan(/[[:alnum:]_]+/).map { |word| word.sub(/s\z/, '') }
        .reject { |word| word.size < 3 || STOP_WORDS.include?(word) }.uniq
  end

  def relevance(text, query)
    (search_words(text) & search_words(query)).size
  end

  def evidence_query(item)
    latest = item.fetch('comments').fetch('nodes').reject { |comment| bot?(comment['author']) }.last
    [item['title'], item['body'], latest&.fetch('body')].compact.join("\n")
  end

  def ranked_sources(item)
    query = evidence_query(item)
    ranked = source_paths.map do |path|
      score = (relevance(path, query) * 3) + relevance(File.read(path), query)
      [path, score]
    end
    ranked.sort_by { |path, score| [-score, path] }.first(8).map(&:first)
  end

  def source_excerpt(path, query)
    text = File.read(path)
    return text if text.bytesize <= 6000

    cache_evidence(['excerpt-v1', path, Digest::SHA256.hexdigest(text), search_words(query).sort]) do
      lines = text.lines
      windows = (0...lines.size).step(40).map do |offset|
        body = lines[offset, 60].join
        [offset, body, relevance(body, query)]
      end
      offset, body, = windows.max_by { |start, _body, score| [score, -start] }
      "Excerpt, starting at line #{offset + 1}; surrounding content omitted:\n#{bounded_text(body, 5600)}"
    end
  end

  def bounded_text(text, bytes)
    return text if text.bytesize <= bytes

    "#{text.byteslice(0, bytes).force_encoding(Encoding::UTF_8).scrub('')}\n[remaining content omitted]"
  end

  def cache_evidence(key, ttl: nil)
    directory = @environment['TRIAGE_EVIDENCE_DIR']
    path = File.join(directory, "#{Digest::SHA256.hexdigest(JSON.generate([@repository, key]))}.json") if directory
    if path && File.file?(path) && (!ttl || Time.now - File.mtime(path) < ttl)
      begin
        return JSON.parse(File.read(path))
      rescue JSON::ParserError
        # Rebuild disposable evidence; conversation state is stored separately.
      end
    end
    value = yield
    if path
      FileUtils.mkdir_p(directory)
      File.write("#{path}.tmp", JSON.generate(value))
      File.rename("#{path}.tmp", path)
    end
    value
  end

  def validate_lookup(lookup)
    raise ArgumentError unless lookup.is_a?(Array) && lookup.size.between?(1, 2)

    lookup.each do |call|
      raise ArgumentError unless call.is_a?(Hash) && call.keys.sort == %w[query tool]
      raise ArgumentError unless %w[docs releases resolved_issues].include?(call['tool'])
      raise ArgumentError unless call['query'].is_a?(String) && call['query'].bytesize.between?(1, 200)
    end
  end

  def lookup_answer(item, calls)
    @evidence_records = {}
    sources = calls.flat_map do |call|
      if call.fetch('tool') == 'docs'
        query = call.fetch('query')
        source_paths.sort_by { |path| [-relevance("#{path}\n#{File.read(path)}", query), path] }.first(2).map do |path|
          [path, source_excerpt(path, query)]
        end
      else
        lookup_remote(call.fetch('tool'), call.fetch('query'))
      end
    end.to_h
    return if sources.empty?

    answer_from_sources(item, sources)
  end

  def lookup_remote(tool, query)
    records = cache_evidence(['remote-v1', tool], ttl: 300) do
      remote_catalog(tool)
    end
    records = records.reject { |record| record['isDraft'] } if tool == 'releases'
    ranked = records.map do |record|
      title = record['title'] || record['name'] || record['tagName']
      body = record['body'] || record['description'] || ''
      [record, (relevance(title, query) * 3) + relevance(body, query)]
    end
    ranked.select! { |_record, score| score.positive? }
    ranked.sort_by { |record, score| [-score, record.fetch('id')] }.first(2).map do |record, _score|
      id = "#{tool}:#{record.fetch('id')}"
      @evidence_records[id] = record.merge('tool' => tool)
      excerpt = record.transform_values { |value| value.is_a?(String) ? bounded_text(value, 4000) : value }
      [id, JSON.generate(excerpt)]
    end
  end

  def remote_catalog(tool)
    owner, name = @repository.split('/', 2)
    field = if tool == 'releases'
              "releases(first: 20, orderBy: {field: CREATED_AT, direction: DESC}) { nodes { #{RELEASE_FIELDS} } }"
            else
              'issues(first: 30, states: CLOSED, orderBy: {field: UPDATED_AT, direction: DESC}) ' \
                "{ nodes { #{RESOLVED_FIELDS} } }"
            end
    query = "query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { #{field} } }"
    @evidence_reads = (@evidence_reads || 0) + 1
    repository = github('graphql', query: query,
                                   variables: { owner: owner, name: name }).fetch('data').fetch('repository')
    repository.fetch(tool == 'releases' ? 'releases' : 'issues').fetch('nodes')
  end

  def verify_evidence
    records = @used_evidence || []
    return if records.empty?

    query = <<~GRAPHQL
      query($ids: [ID!]!) { nodes(ids: $ids) {
        ... on Release { #{RELEASE_FIELDS} }
        ... on Issue { #{RESOLVED_FIELDS} }
      } }
    GRAPHQL
    current = github('graphql', query: query, variables: { ids: records.map { |record| record.fetch('id') } })
              .fetch('data').fetch('nodes')
    return if current == records.map { |record| record.except('tool') }

    raise IssueAssessment::Skipped, 'release or resolved-issue evidence changed during assessment'
  end

  def evidence_link(id)
    record = @evidence_records && @evidence_records[id]
    return source_link(id) unless record

    url = record.fetch('url')
    prefix = "#{@environment.fetch('GITHUB_SERVER_URL', 'https://github.com')}/#{@repository}/"
    raise ArgumentError unless url.start_with?(prefix) && url.match?(%r{\Ahttps://[^\s<>()\[\]]+\z})

    label = record['tool'] == 'releases' ? 'release notes' : "##{record.fetch('number')}"
    "[#{label}](#{url})"
  end
end
