# frozen_string_literal: true

require 'json'
require 'yaml'
require 'open3'
require 'digest'
require 'uri'

# Read-only, repository-scoped tools. Retrieval is mechanical; the agent chooses
# queries, follows references, interprets evidence, and decides when to stop.
class TriageTools
  MAX_CALLS = 12
  MAX_RESULT_BYTES = 8000
  SCHEMAS = {
    'search_repository' => {
      description: 'Find literal, case-insensitive text in configured repository docs/code. ' \
                   'Returns matching lines with file references and byte offsets. Use a short term, ' \
                   'not a question; try another spelling if needed. Empty query lists files. ' \
                   'path optionally limits results to a directory prefix. Follow next_offset to paginate.',
      properties: { query: { type: 'string', maxLength: 200 }, path: { type: 'string', maxLength: 200 },
                    offset: { type: 'integer', minimum: 0 } }, required: ['query']
    },
    'search_issues' => {
      description: 'Search this repository’s issues using GitHub search. query is plain keywords, ' \
                   'not search qualifiers. Returns up to five titles and body previews; read a reference ' \
                   'before deciding duplication. state can be open, closed, or all. Follow next_page for more.',
      properties: { query: { type: 'string', maxLength: 200 }, state: { type: 'string', enum: %w[open closed all] },
                    page: { type: 'integer', minimum: 1, maximum: 10 } }, required: ['query']
    },
    'list_releases' => {
      description: 'List five published releases, newest first, with version, date, prerelease flag, ' \
                   'and short notes. Read a reference for full notes. Follow next_page for older releases. ' \
                   'A closed issue or code on main is not proof of a released fix.',
      properties: { page: { type: 'integer', minimum: 1, maximum: 10 } }, required: []
    },
    'read_evidence' => {
      description: 'Read a file, issue (body and latest comments), or release from this repository. ' \
                   'Use the exact reference returned by a search, e.g. file:docs/guide.md, issue:42, release:123. ' \
                   'Returns at most 6 KB of text, a citation reference, and next_offset when more remains. ' \
                   'offset is a byte offset; repository search supplies offsets near matches. ' \
                   'Only references read with this tool may be cited in the final decision.',
      properties: { reference: { type: 'string', maxLength: 400 }, offset: { type: 'integer', minimum: 0 } },
      required: ['reference']
    },
    'submit_decision' => {
      description: 'Finish triage with a structured decision. This records a proposal, not a GitHub write. ' \
                   'Use null reply/comment for silence. The publisher checks citations and closure permissions. ' \
                   'Submit once, after investigation; no more evidence tools are available afterwards.',
      properties: {
        labels: { type: 'array', items: { type: 'string' }, maxItems: 2 },
        reply: { type: %w[string null], maxLength: 100 },
        comment: { type: %w[string null], maxLength: 2000 },
        sources: { type: 'array', items: { type: 'string' }, maxItems: 3 },
        related_issue: { type: %w[integer null], minimum: 1 },
        relationship: { type: %w[string null], enum: ['related', 'duplicate', nil] },
        mute: { type: 'boolean' }
      }, required: %w[labels reply comment sources related_issue relationship mute]
    }
  }.freeze

  attr_reader :ledger

  def self.definitions
    SCHEMAS.map do |name, schema|
      { name: name, description: schema.fetch(:description),
        inputSchema: { type: 'object', properties: schema.fetch(:properties),
                       required: schema.fetch(:required), additionalProperties: false },
        annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false } }
    end
  end

  def initialize(root:, repository:, config:, ledger_path: nil, token: nil)
    @root = File.realpath(root)
    @repository = repository
    raise ArgumentError, 'Invalid repository' unless repository.match?(%r{\A[\w.-]+/[\w.-]+\z})

    @config = config
    @ledger_path = ledger_path
    @token = token
    @ledger = { 'calls' => 0, 'bytes' => 0, 'evidence' => {} }
    @records = {}
  end

  def call(name, arguments)
    raise ArgumentError, 'Decision already submitted; end the turn.' if @ledger['decision']
    if name != 'submit_decision' && @ledger['calls'] >= MAX_CALLS
      raise ArgumentError, 'Evidence tool budget exhausted; submit your decision.'
    end

    @ledger['calls'] += 1 unless name == 'submit_decision'
    validate_arguments(name, arguments)
    result = public_send(name, **arguments.transform_keys(&:to_sym))
    text = JSON.generate(result)
    raise ArgumentError, 'Result too large; narrow the request.' if text.bytesize > MAX_RESULT_BYTES

    @ledger['bytes'] += text.bytesize
    { content: [{ type: 'text', text: text }] }
  rescue ArgumentError, KeyError, IOError, SystemCallError => e
    { isError: true, content: [{ type: 'text', text: e.message }] }
  ensure
    File.write(@ledger_path, JSON.generate(@ledger)) if @ledger_path
  end

  def search_repository(query:, path: '', offset: 0)
    matches = []
    paths.each do |file|
      next unless file.start_with?(path)

      if query.empty?
        matches << { reference: "file:#{file}", bytes: File.size(File.join(@root, file)) }
      else
        position = 0
        File.foreach(File.join(@root, file)).with_index(1) do |line, number|
          if line.downcase.include?(query.downcase)
            matches << { reference: "file:#{file}", line: number, offset: [position - 300, 0].max,
                         text: clip(line.strip, 400) }
          end
          position += line.bytesize
          break if matches.size > offset + 10
        end
      end
      break if matches.size > offset + 10
    end
    results = matches.drop(offset).first(10)
    { results: results, next_offset: matches.size > offset + results.size ? offset + results.size : nil }
  end

  def search_issues(query:, state: 'all', page: 1)
    # Quote each word so a tool argument cannot introduce repo/org/search qualifiers.
    terms = query.scan(/[[:alnum:]_.-]+/).map { |word| %("#{word}") }.join(' ')
    search = "#{terms} repo:#{@repository} is:issue"
    search += " is:#{state}" unless state == 'all'
    data = api("search/issues?#{URI.encode_www_form(q: search, per_page: 5, page: page)}")
    results = data.fetch('items').map do |issue|
      { reference: "issue:#{issue.fetch('number')}", title: clip(issue.fetch('title'), 250),
        state: issue.fetch('state'), preview: clip(issue['body'].to_s, 600) }
    end
    { results: results, next_page: page * 5 < data.fetch('total_count') && page < 10 ? page + 1 : nil,
      incomplete: data.fetch('incomplete_results', false) || data.fetch('total_count') > 50 }
  end

  def list_releases(page: 1)
    releases = api("repos/#{@repository}/releases?per_page=5&page=#{page}")
    results = releases.reject { |release| release['draft'] }.map do |release|
      { reference: "release:#{release.fetch('id')}", version: clip(release.fetch('tag_name'), 150),
        published_at: release['published_at'], prerelease: release.fetch('prerelease'),
        preview: clip(release['body'].to_s, 700) }
    end
    { results: results, next_page: releases.size == 5 && page < 10 ? page + 1 : nil }
  end

  def read_evidence(reference:, offset: 0)
    record = @records[reference] ||= fetch_record(reference)
    content = record.fetch('content')
    raise ArgumentError, 'Offset is beyond the content.' if offset > content.bytesize

    text = clip(content.byteslice(offset..), 6000)
    result = { reference: reference, content: text, offset: offset, total_bytes: content.bytesize }
    while JSON.generate(result).bytesize > MAX_RESULT_BYTES - 100
      text = clip(text, text.bytesize / 2)
      result[:content] = text
    end
    finish = offset + text.bytesize
    result[:next_offset] = finish < content.bytesize ? finish : nil
    entry = @ledger['evidence'][reference] ||= record.except('content').merge('ranges' => [])
    entry['ranges'] << [offset, finish]
    covered = entry['ranges'].sort.reduce(0) do |end_at, (start_at, stop_at)|
      start_at <= end_at ? [end_at, stop_at].max : end_at
    end
    entry['complete'] = covered >= content.bytesize
    result
  end

  def submit_decision(**decision)
    unless (decision.fetch(:labels) - @config.fetch('labels').keys).empty?
      raise ArgumentError,
            'Choose only configured labels.'
    end

    reply = decision.fetch(:reply)
    raise ArgumentError, 'Unknown configured reply.' if reply && !@config.fetch('replies').key?(reply)
    raise ArgumentError, 'Use either comment or a configured reply, not both.' if reply && decision[:comment]

    sources = decision.fetch(:sources)
    raise ArgumentError, 'Read the cited references first.' unless (sources - @ledger['evidence'].keys).empty?

    references = decision[:comment].to_s.scan(/\[\[([^\]]+)\]\]/).flatten
    raise ArgumentError, 'Citations must match sources.' unless references.uniq.sort == sources.uniq.sort

    @ledger['decision'] = decision.transform_keys(&:to_s)
    { accepted: true }
  end

  # Also used by the publisher to recheck cited remote evidence before mutation.
  def fetch_record(reference)
    kind, id = reference.split(':', 2)
    if kind == 'file'
      raise ArgumentError, 'File is not an allowed source.' unless paths.include?(id)

      content = File.read(File.join(@root, id), encoding: 'UTF-8')
      raise ArgumentError, 'Source is not UTF-8 text.' unless content.valid_encoding?

      return { 'kind' => kind, 'path' => id, 'digest' => Digest::SHA256.hexdigest(content), 'content' => content }
    end
    raise ArgumentError, 'Expected file:path, issue:number, or release:id.' unless
      %w[issue release].include?(kind) && id&.match?(/\A[1-9]\d*\z/)

    route = kind == 'issue' ? 'issues' : 'releases'
    data = api("repos/#{@repository}/#{route}/#{id}")
    raise ArgumentError, 'Pull requests are not issue evidence.' if data['pull_request']
    raise ArgumentError, 'Draft releases are unavailable.' if data['draft']

    fields = if kind == 'issue'
               %w[node_id number title body state state_reason html_url updated_at]
             else
               %w[id tag_name name body html_url published_at prerelease draft]
             end
    snapshot = data.slice(*fields)
    if kind == 'issue'
      count = data.fetch('comments', 0)
      # The final page contains the newest comments; no full-thread dump.
      page = [(count / 5.0).ceil, 1].max
      comments = count.zero? ? [] : api("repos/#{@repository}/issues/#{id}/comments?per_page=5&page=#{page}")
      snapshot['comments'] = comments.map { |comment| comment.slice('body', 'author_association', 'updated_at') }
    end
    { 'kind' => kind, 'url' => data.fetch('html_url'), 'snapshot' => snapshot,
      'digest' => Digest::SHA256.hexdigest(JSON.generate(snapshot)), 'content' => JSON.pretty_generate(snapshot) }
  end

  private

  def paths
    @config.fetch('sources', []).flat_map { |pattern| Dir.glob(pattern, base: @root) }.uniq.sort.select do |path|
      absolute = File.join(@root, path)
      !path.start_with?('/') && !path.split('/').include?('..') && File.file?(absolute) &&
        !File.symlink?(absolute) && File.realpath(absolute).start_with?("#{@root}/") && File.size(absolute) <= 1_000_000
    end
  end

  def validate_arguments(name, arguments)
    schema = SCHEMAS.fetch(name) { raise ArgumentError, 'Unknown tool.' }
    properties = schema.fetch(:properties).transform_keys(&:to_s)
    raise ArgumentError, 'Invalid tool arguments.' unless arguments.is_a?(Hash) &&
                                                          (arguments.keys - properties.keys).empty? &&
                                                          (schema.fetch(:required) - arguments.keys).empty?

    arguments.each do |key, value|
      type = properties.fetch(key)
      valid = Array(type[:type]).any? { |name| valid_type?(name, value, type) }
      raise ArgumentError, "Invalid #{key}." unless valid && (!type[:enum] || type[:enum].include?(value))
    end
  end

  def valid_type?(name, value, schema)
    case name
    when 'null' then value.nil?
    when 'boolean' then [true, false].include?(value)
    when 'array'
      value.is_a?(Array) && value.size <= schema.fetch(:maxItems) &&
        value.all? { |entry| entry.is_a?(String) && entry.bytesize <= 400 }
    when 'integer'
      value.is_a?(Integer) && value >= schema.fetch(:minimum) && value <= schema.fetch(:maximum, 1_000_000)
    when 'string'
      value.is_a?(String) && value.bytesize <= schema.fetch(:maxLength, 200) && !value.include?("\0")
    end
  end

  def clip(text, bytes)
    text.byteslice(0, bytes).to_s.force_encoding(Encoding::UTF_8).scrub('')
  end

  def api(endpoint)
    output, _errors, status = Open3.capture3({ 'GH_TOKEN' => @token }, 'timeout', '15s', 'gh', 'api',
                                             '--method', 'GET', endpoint)
    raise IOError, 'GitHub read failed; try another source or leave this for a maintainer.' unless status.success?

    JSON.parse(output)
  rescue JSON::ParserError
    raise IOError, 'GitHub returned invalid data; try another source or leave this for a maintainer.'
  end
end
