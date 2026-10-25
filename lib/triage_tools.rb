# frozen_string_literal: true

require 'json'
require 'yaml'
require 'open3'
require 'digest'
require 'uri'
require_relative 'project_board'

# Read-only, repository-scoped tools. Retrieval is mechanical; the agent chooses
# queries, follows references, interprets evidence, and decides when to stop.
class TriageTools
  MAX_CALLS = 12
  MAX_RESULT_BYTES = 8000
  UNRELEASED_PAGES = 5
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
    'search_changes' => {
      description: 'Find which release ships a change, or whether it is still unreleased. Returns release notes ' \
                   'that mention query (released, with version; read a reference for full notes) and commits on ' \
                   'the default branch since the latest stable release whose message mentions it (unreleased, ' \
                   'newest first). Repository files show the default branch: what they contain shipped in the ' \
                   'latest release unless it is among the unreleased commits. query is literal, case-insensitive ' \
                   'text; empty lists the unreleased commits. Follow next_offset for more unreleased commits.',
      properties: { query: { type: 'string', maxLength: 200 }, offset: { type: 'integer', minimum: 0 } },
      required: ['query']
    },
    'read_evidence' => {
      description: 'Read a file, issue (body and latest comments), or release from this repository. ' \
                   'Use the exact reference returned by a search, e.g. file:docs/guide.md, issue:42, release:123. ' \
                   'Returns at most 6 KB of text, a citation reference, and next_offset when more remains. ' \
                   'A file shows the default branch; revision says when it is ahead of the latest release. ' \
                   'offset is a byte offset; repository search supplies offsets near matches. ' \
                   'Page size is fixed: pass only reference and optional offset, not a length or limit. ' \
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
  # Extra submit_decision arguments when the repository keeps a project board.
  BOARD_PROPERTIES = {
    next_move: { type: 'string', enum: %w[sign_off decide do theirs not_now] },
    priority: { type: 'string', enum: %w[urgent high normal] },
    next_step: { type: 'string', maxLength: 160 }
  }.freeze

  # Extra submit_decision arguments when assessing a pull request.
  PULL_REQUEST_PROPERTIES = {
    review: { type: 'boolean' },
    out_of_scope: { type: 'boolean' }
  }.freeze
  # Extra submit_decision argument for a new discussion when the policy moves reports to issues.
  MOVE_PROPERTIES = { move_to_issue: { type: 'boolean' } }.freeze
  # Extra submit_decision argument for an issue: a proposed closure.
  CLOSE_PROPERTIES = { close_as: { type: %w[string null], enum: ['fixed', 'resolved', 'out_of_scope', nil] } }.freeze
  # Extra submit_decision argument for an issue: labels it has that come off,
  # such as needs-info once the reporter supplied what it asked for.
  REMOVE_LABEL_PROPERTIES = { remove_labels: { type: 'array', items: { type: 'string' }, maxItems: 2 } }.freeze
  # Extra submit_decision argument for an issue: a pull request from the
  # report's pull_requests that may fix it.
  CANDIDATE_FIX_PROPERTIES = { candidate_fix: { type: %w[integer null], minimum: 1 } }.freeze
  # Every extra submit_decision argument for an issue.
  ISSUE_PROPERTIES = CLOSE_PROPERTIES.merge(REMOVE_LABEL_PROPERTIES, CANDIDATE_FIX_PROPERTIES).freeze
  DIFF_HINT = ' For the pull request being assessed, diff:path reads the patch of a changed file.'
  # A pull request reply that quotes code, points at a line, or discusses an
  # identifier, such as drag_delta, reviews code, which belongs to the
  # maintainer and the review bots. Paths and file names are fine.
  CODE_REVIEW = /```|\S\.\w+:\d+|\blines? \d+|::|\b\w+\(\)|\b[a-z]+_[a-z0-9_]+\b/i

  attr_reader :ledger

  def self.schemas(board: false, pull_request: false, move: false, issue: false)
    extra = {}
    extra.merge!(BOARD_PROPERTIES) if board
    extra.merge!(PULL_REQUEST_PROPERTIES) if pull_request
    extra.merge!(MOVE_PROPERTIES) if move
    extra.merge!(ISSUE_PROPERTIES) if issue
    submit = SCHEMAS.fetch('submit_decision')
    schemas = SCHEMAS.merge('submit_decision' => submit.merge(
      properties: submit.fetch(:properties).merge(extra), required: submit.fetch(:required) + extra.keys.map(&:to_s)
    ))
    return schemas unless pull_request

    read = schemas.fetch('read_evidence')
    schemas.merge('read_evidence' => read.merge(description: read.fetch(:description) + DIFF_HINT))
  end

  def self.definitions(board: false, pull_request: false, move: false, issue: false)
    schemas(board:, pull_request:, move:, issue:).map do |name, schema|
      { name: name, description: schema.fetch(:description),
        inputSchema: { type: 'object', properties: schema.fetch(:properties),
                       required: schema.fetch(:required), additionalProperties: false },
        annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false } }
    end
  end

  # Labels that say what kind of report it is. Once a report has one, from a
  # maintainer or an earlier run, the agent adds no other.
  TYPE_LABELS = %w[bug enhancement question documentation].freeze
  # Labels that cannot describe the same report.
  CONTRADICTIONS = [%w[bug enhancement], %w[wontfix enhancement], %w[out-of-scope enhancement]].freeze
  # Labels that rule a request out, so it has nothing to track as an issue.
  DECLINING_LABELS = %w[wontfix out-of-scope invalid].freeze

  # Why these labels cannot be added to a report that already has existing, or nil.
  def self.label_conflict(labels, existing)
    added = labels - existing
    pair = CONTRADICTIONS.find { |names| (names - labels - existing).empty? && names.intersect?(added) }
    return "#{pair.join(' and ')} contradict each other; keep the one that fits." if pair

    type = (existing & TYPE_LABELS).first
    return unless type && added.intersect?(TYPE_LABELS)

    "This report is already labeled #{type}; add no other type label (#{TYPE_LABELS.join(', ')})."
  end

  # Why this report cannot be closed as a duplicate of the issue snapshot, or
  # nil. A target closed as completed means the bug came back, and an error
  # tracker reopens its report when the error recurs. A reporter who closed
  # their issue and filed it again left this report as the one to keep.
  def self.duplicate_conflict(snapshot, report)
    number = snapshot['number']
    recurrence = "link ##{number} as related instead, and say this looks like a recurrence of it."
    if report['recurring']
      "The error tracker reopened this report because the error recurred: #{recurrence}"
    elsif snapshot['state'] == 'closed' && snapshot['state_reason'] == 'completed'
      "##{number} was closed as completed, so this is not a duplicate: #{recurrence}"
    elsif snapshot['state'] == 'closed' && report['author'] && snapshot['author'] == report['author']
      "##{number} is closed and has the same author, who filed this report again: this one is the live copy, " \
        'so link it as related instead.'
    end
  end

  # report describes the item under assessment, for checks on the decision.
  def initialize(root:, repository:, config:, ledger_path: nil, token: nil, board: false, pull_request: nil,
                 move: false, issue: false, report: nil, number: nil)
    @root = File.realpath(root)
    @report = report || {}
    @board = board
    @pull_request = pull_request
    @move = move
    @issue = issue
    @number = number
    @repository = repository
    raise ArgumentError, 'Invalid repository' unless repository.match?(%r{\A[\w.-]+/[\w.-]+\z})

    @config = config
    @ledger_path = ledger_path
    @token = token
    @ledger = { 'calls' => 0, 'bytes' => 0, 'evidence' => {} }
    @records = {}
  end

  def definitions
    self.class.definitions(**schema_options)
  end

  def schema_options
    { board: @board, pull_request: !@pull_request.nil?, move: @move, issue: @issue }
  end

  def call(name, arguments)
    raise ArgumentError, 'Decision already submitted; end the turn.' if @ledger['decision']
    if name != 'submit_decision' && @ledger['calls'] >= MAX_CALLS
      raise ArgumentError, 'Evidence tool budget exhausted; submit your decision.'
    end

    @ledger['calls'] += 1 unless name == 'submit_decision'
    trace = { 'tool' => name, 'arguments' => arguments }
    (@ledger['trace'] ||= []) << trace
    validate_arguments(name, arguments)
    result = public_send(name, **arguments.transform_keys(&:to_sym))
    text = JSON.generate(result)
    raise ArgumentError, 'Result too large; narrow the request.' if text.bytesize > MAX_RESULT_BYTES

    @ledger['bytes'] += text.bytesize
    { content: [{ type: 'text', text: text }] }
  rescue ArgumentError, KeyError, IOError, SystemCallError => e
    trace['error'] = e.message if trace
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

  def search_changes(query:, offset: 0)
    baseline = release_baseline
    return { latest_release: nil, note: 'No stable release is published.' } unless baseline

    term = query.downcase
    released = recent_releases.select { |release| release['body'].to_s.downcase.include?(term) }.first(5)
    unreleased = unreleased_commits.select { |commit| commit.fetch(:message).downcase.include?(term) }
    page = unreleased.drop(offset).first(10)
    { latest_release: baseline.fetch(:version), published_at: baseline.fetch(:published_at),
      commits_since: baseline.fetch(:commits_since),
      released: (offset.zero? ? released : []).map { |release| release_match(release, term) },
      unreleased: page.map do |commit|
        { commit: commit.fetch(:sha), date: commit.fetch(:date),
          subject: clip(commit.fetch(:message).lines.first.strip, 200) }
      end,
      next_offset: unreleased.size > offset + page.size ? offset + page.size : nil,
      incomplete: unreleased_commits.size < baseline.fetch(:commits_since) }
  end

  # The newest stable release and how many default-branch commits came after
  # it, or nil when no stable release is published.
  def release_baseline
    return @release_baseline if defined?(@release_baseline)

    release = recent_releases.find { |candidate| !candidate['prerelease'] }
    @release_baseline = release && begin
      @compare_pages = [compare_page(release.fetch('tag_name'), 1)]
      { version: clip(release.fetch('tag_name'), 150), published_at: release['published_at'],
        commits_since: @compare_pages.first.fetch('ahead_by') }
    end
  end

  def read_evidence(reference:, offset: 0)
    record = @records[reference] ||= fetch_record(reference)
    content = record.fetch('content')
    raise ArgumentError, 'Offset is beyond the content.' if offset > content.bytesize

    text = clip(content.byteslice(offset..), 6000)
    result = { reference: reference, revision: file_revision(record), content: text, offset: offset,
               total_bytes: content.bytesize }.compact
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

    if @move && decision[:labels].any? && !decision[:move_to_issue]
      raise ArgumentError, 'Labels apply only to an issue created by move_to_issue; use [] for a discussion that stays.'
    end
    if decision[:move_to_issue] && decision[:labels].intersect?(DECLINING_LABELS)
      raise ArgumentError, 'A request your labels rule out stays a discussion: answer it here with move_to_issue ' \
                           'false and no labels.'
    end

    label_removal!(decision)
    remaining = @report.fetch('labels', []) - decision.fetch(:remove_labels, [])
    conflict = self.class.label_conflict(decision[:labels], remaining)
    raise ArgumentError, conflict if conflict

    reply = decision.fetch(:reply)
    raise ArgumentError, 'Unknown configured reply.' if reply && !@config.fetch('replies').key?(reply)
    raise ArgumentError, 'Use either comment or a configured reply, not both.' if reply && decision[:comment]

    # A move only hands the report to the new issue's assessment, which finds
    # and cites its own evidence, so the move's one sentence carries none.
    if decision[:move_to_issue] && decision.fetch(:sources).any?
      decision[:comment] = decision[:comment].to_s.gsub(/\s*\[\[[^\]]+\]\]/, '').strip.then { _1.empty? ? nil : _1 }
      decision[:sources] = []
    end
    sources = decision.fetch(:sources)
    raise ArgumentError, 'Read the cited references first.' unless (sources - @ledger['evidence'].keys).empty?
    if @number && (sources.include?("issue:#{@number}") || decision[:related_issue] == @number)
      raise ArgumentError, "issue:#{@number} is this report itself; cite other evidence or none."
    end
    if sources.any? && !decision[:comment]
      raise ArgumentError,
            'Cite sources only in a comment; with no comment, use [].'
    end
    if decision[:related_issue].nil? != decision[:relationship].nil?
      raise ArgumentError, 'Set related_issue and relationship together, or leave both null.'
    end
    if decision[:related_issue] && !decision[:comment]
      raise ArgumentError, 'Explain the relationship to the related issue in comment.'
    end
    if sources.any? { |source| source.start_with?('diff:') }
      raise ArgumentError, 'Diffs are evidence for you, not citations.'
    end
    if @pull_request && code_review?(decision[:comment])
      raise ArgumentError, 'Do not review code in a pull request reply: no code, identifiers, or line numbers. ' \
                           'Reply only for a policy requirement or an essential question.'
    end
    if (decision[:out_of_scope] || decision[:close_as]) && !decision[:comment]
      raise ArgumentError, 'Explain in comment why it can be closed.'
    end

    close_evidence!(decision) if decision[:close_as]
    candidate_fix!(decision) if decision[:candidate_fix]
    release_checked!(sources)

    if decision[:related_issue]
      reference = "issue:#{decision[:related_issue]}"
      entry = @ledger['evidence'][reference]
      unless entry && entry['complete']
        raise ArgumentError, "Read #{reference} completely with read_evidence before submitting an issue relationship."
      end

      conflict = self.class.duplicate_conflict(entry['snapshot'], @report) if decision[:relationship] == 'duplicate'
      raise ArgumentError, conflict if conflict
    end

    references = decision[:comment].to_s.scan(/\[\[([^\]]+)\]\]/).flatten
    raise ArgumentError, 'Citations must match sources.' unless references.uniq.sort == sources.uniq.sort
    if @board && !ProjectBoard.next_step?(decision[:next_step])
      raise ArgumentError, 'next_step must be one non-empty line under 160 bytes.'
    end

    @ledger['decision'] = decision.transform_keys(&:to_s)
    { accepted: true }
  end

  def code_review?(comment)
    return false unless comment

    words = comment.gsub(/\[\[[^\]]*\]\]/, '').split.reject { |word| word.match?(%r{/|\.\w}) && !word.match?(/:\d/) }
    comment.include?('```') || words.join(' ').match?(CODE_REVIEW)
  end

  # A label comes off only when the issue has it, the policy allows it, and
  # the reporter spoke last, answering what it asked for.
  def label_removal!(decision)
    removed = decision.fetch(:remove_labels, [])
    return if removed.empty?

    unless (removed - @report.fetch('labels', [])).empty? && (removed - @config.fetch('labels').keys).empty?
      raise ArgumentError, 'remove_labels may name only configured labels this issue has now.'
    end
    raise ArgumentError, 'Do not add and remove the same label.' if removed.intersect?(decision.fetch(:labels))
    return if @report['author'] && @report['latest_commenter'] == @report['author']

    raise ArgumentError, 'Remove a label only when the reporter, in the latest comment, supplied what it asked ' \
                         'for. Use remove_labels [].'
  end

  # Pull requests are not issue evidence, so a candidate fix comes from the
  # report's own list, which the wrapper links like a related issue.
  def candidate_fix!(decision)
    unless @report.fetch('pull_requests', []).include?(decision[:candidate_fix])
      raise ArgumentError, "candidate_fix must be a number from the report's pull_requests, or null."
    end
    raise ArgumentError, 'Link a related issue or a candidate fix, not both.' if decision[:related_issue]
    return if decision[:comment]

    raise ArgumentError, 'Explain in comment how the pull request may fix this.'
  end

  # A closure must rest on evidence the agent read: release notes for a fix,
  # documented scope for out of scope, the reporter's own latest comment for
  # resolved.
  def close_evidence!(decision)
    if decision[:close_as] == 'resolved' && @report['author'] && @report['latest_commenter'] != @report['author']
      raise ArgumentError, 'close_as resolved needs the reporter to say so in the latest comment, and someone ' \
                           'else spoke last. Set close_as null and do not say the issue is resolved or closing.'
    end

    kind = { 'fixed' => 'release:', 'out_of_scope' => 'file:' }[decision[:close_as]]
    return if kind.nil? || decision.fetch(:sources).any? { |source| source.start_with?(kind) }

    raise ArgumentError, "Cite the #{kind.delete(':')} you read that establishes close_as #{decision[:close_as]}."
  end

  # Files show the default branch. A reply citing them must first check what
  # the latest stable release lacks, unless the evidence budget is spent.
  def release_checked!(sources)
    return if @pull_request || sources.none? { |source| source.start_with?('file:') }
    return if @ledger['calls'] >= MAX_CALLS || @ledger['trace'].any? { |entry| entry['tool'] == 'search_changes' }

    baseline = begin
      release_baseline
    rescue IOError
      nil
    end
    return unless baseline&.fetch(:commits_since)&.positive?

    raise ArgumentError, "Repository files are #{baseline.fetch(:commits_since)} commits ahead of " \
                         "#{baseline.fetch(:version)}. Check search_changes for what you cite, " \
                         'and do not present unreleased work as available.'
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
    return fetch_diff(id) if kind == 'diff'
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
      snapshot['author'] = data.dig('user', 'login')
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

  # The patch of one file changed by the pull request under assessment, read
  # through the API. Contributor code is never checked out or run.
  def fetch_diff(path)
    raise ArgumentError, 'diff:path is only available when assessing a pull request.' unless @pull_request

    file = changed_files.find { |entry| entry['filename'] == path }
    raise ArgumentError, 'That file is not changed by this pull request; use a path from the file list.' unless file

    content = file['patch'] || "No text patch for this #{file['status']} file (binary or too large)."
    { 'kind' => 'diff', 'path' => path, 'digest' => Digest::SHA256.hexdigest(content), 'content' => content }
  end

  # Beside each file read, not in its content, so offsets and the digest the
  # publisher rechecks stay those of the file.
  def file_revision(record)
    return if record['kind'] != 'file' || @pull_request || @baseline_failed

    baseline = begin
      release_baseline
    rescue IOError, KeyError
      @baseline_failed = true
      nil
    end
    since = baseline&.fetch(:commits_since).to_i
    return unless since.positive?

    "(default branch, #{since} #{since == 1 ? 'commit' : 'commits'} after #{baseline.fetch(:version)})"
  end

  def changed_files
    @changed_files ||= (1..10).each_with_object([]) do |page, files|
      batch = api("repos/#{@repository}/pulls/#{@pull_request}/files?per_page=100&page=#{page}")
      files.concat(batch)
      break files if batch.size < 100
    end
  end

  def paths
    @config.fetch('sources', []).flat_map { |pattern| Dir.glob(pattern, base: @root) }.uniq.sort.select do |path|
      absolute = File.join(@root, path)
      !path.start_with?('/') && !path.split('/').include?('..') && File.file?(absolute) &&
        !File.symlink?(absolute) && File.realpath(absolute).start_with?("#{@root}/") && File.size(absolute) <= 1_000_000
    end
  end

  def validate_arguments(name, arguments)
    schema = self.class.schemas(**schema_options).fetch(name) do
      raise ArgumentError, 'Unknown tool.'
    end
    properties = schema.fetch(:properties).transform_keys(&:to_s)
    raise ArgumentError, 'Tool arguments must be an object.' unless arguments.is_a?(Hash)

    unknown = arguments.keys - properties.keys
    unless unknown.empty?
      raise ArgumentError, "Unknown arguments: #{unknown.join(', ')}. Allowed arguments: #{properties.keys.join(', ')}."
    end

    missing = schema.fetch(:required) - arguments.keys
    raise ArgumentError, "Missing required arguments: #{missing.join(', ')}." unless missing.empty?

    arguments.each do |key, value|
      type = properties.fetch(key)
      valid = Array(type[:type]).any? { |name| valid_type?(name, value, type) }
      next if valid && (!type[:enum] || type[:enum].include?(value))

      raise ArgumentError, "Invalid #{key}; expected #{JSON.generate(type)}."
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

  # The 50 newest published releases, prereleases included.
  def recent_releases
    @recent_releases ||= api("repos/#{@repository}/releases?per_page=50").reject { |release| release['draft'] }
  end

  def release_match(release, term)
    body = release['body'].to_s
    at = [body.downcase.index(term) - 150, 0].max
    { reference: "release:#{release.fetch('id')}", version: clip(release.fetch('tag_name'), 150),
      published_at: release['published_at'], prerelease: release.fetch('prerelease'),
      excerpt: clip(body.byteslice(at..).to_s.scrub(''), 400) }
  end

  # Default-branch commits after the latest stable release, newest first,
  # up to five pages of 100.
  def unreleased_commits
    @unreleased_commits ||= begin
      tag = release_baseline.fetch(:version)
      pages = (release_baseline.fetch(:commits_since) / 100.0).ceil.clamp(1, UNRELEASED_PAGES)
      @compare_pages += (2..pages).map { |page| compare_page(tag, page) }
      @compare_pages.flat_map { |data| data.fetch('commits') }.reverse.map do |commit|
        { sha: commit.fetch('sha')[0, 12], date: commit.dig('commit', 'committer', 'date'),
          message: commit.dig('commit', 'message').to_s }
      end
    end
  end

  def compare_page(tag, page)
    api("repos/#{@repository}/compare/#{URI.encode_www_form_component(tag)}...HEAD?per_page=100&page=#{page}")
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
