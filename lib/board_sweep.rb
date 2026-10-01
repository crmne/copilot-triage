# frozen_string_literal: true

require 'json'
require 'open3'
require 'yaml'
require_relative 'copilot_review'
require_relative 'project_board'
require_relative 'triage_event'

# Scheduled, model-free board upkeep for one repository. It keeps the project in
# the board's shape, adds open issues and pull requests that are not on it yet,
# applies moves that follow from GitHub facts (who spoke last, linked pull
# requests, checks, and Copilot's verdict on the latest commit), keeps the
# maintainer's review requested on pull requests that need it, and archives
# finished work.
class BoardSweep
  MAX_CHANGES = 100
  # A pull request is never moved out of a question the agent put to the
  # maintainer, or out of the backlog; facts decide everything else.
  PULL_REQUEST_MOVABLE = (ProjectBoard::MOVABLE - ['decide']).freeze
  REVIEW_COLUMNS = %w[approve review].freeze

  def initialize(environment = ENV)
    @environment = environment
    @repository = environment.fetch('GITHUB_REPOSITORY')
    config = YAML.safe_load_file(environment.fetch('TRIAGE_CONFIG', '.github/triage.yml'))
    settings = config['board'] or raise ProjectBoard::Error, 'the sweep needs a board section in the triage policy'
    @maintainer = settings['maintainer'] || settings['assign_urgent_to']
    @board = ProjectBoard.new(settings, token: environment['TRIAGE_PROJECT_TOKEN'])
    @changes = 0
  end

  def run
    unless dry_run?
      setup = @board.set_up
      report("Board set up: #{setup.join(', ')}.") if setup.any?
    end
    @cards = 0
    %w[issues pullRequests].each do |connection|
      each_open(connection) do |node|
        break if @changes >= MAX_CHANGES

        sweep(connection, node)
      end
    end
    archive_finished
    report("Board view added for #{@repository}.") if @cards.positive? && !dry_run? &&
                                                      @board.ensure_repository_view(@repository)
    report("Board sweep: #{@changes} change#{'s' unless @changes == 1}#{' proposed' if dry_run?}.")
    report("Stopped at #{MAX_CHANGES} changes; the next run continues.") if @changes >= MAX_CHANGES
    true
  rescue ProjectBoard::Error => e
    report("Failed: #{e.message}.")
    false
  end

  def issue_column(issue, current, status_updated_at)
    return 'waiting' if issue.dig('closedByPullRequestsReferences', 'totalCount').to_i.positive?

    human = issue.dig('comments', 'nodes').reject { |comment| TriageEvent.bot?(comment['author']) }.last
    yours = bug?(issue) ? 'fix' : 'decide'
    if current.nil?
      return 'backlog' if maintainer?(issue) && (human.nil? || maintainer?(human))

      return human && maintainer?(human) ? 'waiting' : yours
    end
    return unless current == 'waiting' && human && !maintainer?(human)

    yours if status_updated_at.nil? || human.fetch('createdAt') > status_updated_at
  end

  # Returns a column, or :agent for a Copilot "needs a closer look" verdict,
  # which triage judges when the review arrives.
  def pull_request_column(pull)
    own = maintainer?(pull)
    yours_or_theirs = own ? 'fix' : 'waiting'
    return yours_or_theirs if pull['isDraft']

    checks = pull.dig('commits', 'nodes', 0, 'commit', 'statusCheckRollup', 'state')
    return yours_or_theirs if %w[FAILURE ERROR].include?(checks) || pull['mergeable'] == 'CONFLICTING' ||
                              (!own && pull['reviewDecision'] == 'CHANGES_REQUESTED')
    return 'approve' if pull['reviewDecision'] == 'APPROVED' && [nil, 'SUCCESS'].include?(checks) &&
                        pull['mergeable'] == 'MERGEABLE'
    return 'waiting' if CopilotReview.requested?(pull) || %w[PENDING EXPECTED].include?(checks)

    review = CopilotReview.latest(pull)
    case review && review['current'] && review['verdict']
    when 'approve' then 'approve'
    when 'changes' then yours_or_theirs
    when 'closer_look' then :agent
    else own ? 'approve' : 'review'
    end
  end

  private

  def sweep(connection, node)
    item = node.dig('projectItems', 'nodes').find { |entry| entry.dig('project', 'id') == @board.id }
    status = item&.fetch('status', nil)
    current = @board.column_key(status&.fetch('name', nil))
    pull = connection == 'pullRequests'
    column = pull ? pull_request_column(node) : issue_column(node, current, status&.fetch('updatedAt', nil))
    if column == :agent
      judge(node, item) unless dry_run?
      column = current || 'review'
    end
    movable = pull ? PULL_REQUEST_MOVABLE : ProjectBoard::MOVABLE
    final = item && (column.nil? || column == current || !movable.include?(current)) ? current : column
    @cards += 1 if final
    move(node, item, current, final, pull) unless item && final == current
    keep_review_request(node, final) if pull
  end

  # A "needs a closer look" verdict is the agent's call. Triage runs on Copilot's
  # review for same-repository pull requests; for forks, whose review runs get
  # no secrets, the sweep dispatches the triage workflow, once per review: a
  # next step written after the review means it was already judged.
  def judge(pull, item)
    review = CopilotReview.latest(pull)
    judged = item&.dig('next', 'updatedAt')
    return if judged && review && judged > review['submitted_at'].to_s

    workflow = @environment.fetch('TRIAGE_WORKFLOW', 'triage.yml')
    report("PR ##{pull.fetch('number')}: Copilot asks for a closer look; sending it to #{workflow}")
    rest('POST', "repos/#{@repository}/actions/workflows/#{workflow}/dispatches",
         ref: default_branch,
         inputs: { kind: 'pull_request', number: pull.fetch('number').to_s, dry_run: 'false' })
  end

  def move(node, item, current, column, pull)
    label = "#{'PR ' if pull}##{node.fetch('number')}"
    from = if item.nil? then 'new card'
           elsif current then "from #{@board.column_name(current)}"
           else 'from no column'
           end
    report("#{label}: #{from} to #{@board.column_name(column)}")
    @changes += 1
    return if dry_run?

    @board.set_column((item || @board.add(node.fetch('id'))).fetch('id'), column)
  end

  # The maintainer's review is requested while a pull request waits in Approve
  # or Review, and withdrawn when it moves on. GitHub refuses a request to the
  # pull request's own author.
  def keep_review_request(pull, column)
    return unless @maintainer && pull.dig('author', 'login') != @maintainer

    requested = CopilotReview.reviewers(pull).any? { |reviewer| reviewer['login'] == @maintainer }
    wanted = REVIEW_COLUMNS.include?(column)
    return if requested == wanted

    report("PR ##{pull.fetch('number')}: #{wanted ? 'request' : 'withdraw'} @#{@maintainer}'s review")
    return if dry_run?

    path = "repos/#{@repository}/pulls/#{pull.fetch('number')}/requested_reviewers"
    rest(wanted ? 'POST' : 'DELETE', path, reviewers: [@maintainer])
  end

  # Closed issues and closed or merged pull requests leave the board.
  def archive_finished
    owner, name = @repository.split('/', 2)
    query = <<~GRAPHQL
      query($owner: String!, $name: String!) {
        repository(owner: $owner, name: $name) {
          issues(states: CLOSED, last: 50, orderBy: { field: UPDATED_AT, direction: ASC }) {
            nodes { number projectItems(first: 20) { nodes { id project { id } } } }
          }
          pullRequests(states: [CLOSED, MERGED], last: 50, orderBy: { field: UPDATED_AT, direction: ASC }) {
            nodes { number projectItems(first: 20) { nodes { id project { id } } } }
          }
        }
      }
    GRAPHQL
    repository = @board.graphql(query, owner: owner, name: name).fetch('data').fetch('repository')
    (repository.dig('issues', 'nodes') + repository.dig('pullRequests', 'nodes')).each do |node|
      item = node.dig('projectItems', 'nodes').find { |entry| entry.dig('project', 'id') == @board.id }
      next unless item

      report("##{node.fetch('number')}: finished, archived")
      @board.archive(item.fetch('id')) unless dry_run?
    end
  end

  def each_open(connection, &)
    owner, name = @repository.split('/', 2)
    cursor = nil
    loop do
      page = @board.graphql(open_query(connection), owner: owner, name: name, after: cursor)
                   .fetch('data').fetch('repository').fetch(connection)
      page.fetch('nodes').each(&)
      break unless page.dig('pageInfo', 'hasNextPage') && @changes < MAX_CHANGES

      cursor = page.dig('pageInfo', 'endCursor')
    end
  end

  def open_query(connection)
    details = if connection == 'issues'
                'labels(first: 20) { nodes { name } } ' \
                  'comments(last: 5) { nodes { createdAt authorAssociation author { __typename login } } } ' \
                  'closedByPullRequestsReferences(first: 1, includeClosedPrs: false) { totalCount }'
              else
                "isDraft mergeable reviewDecision #{CopilotReview::FIELDS} " \
                  'commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }'
              end
    <<~GRAPHQL
      query($owner: String!, $name: String!, $after: String) {
        repository(owner: $owner, name: $name) {
          #{connection}(states: OPEN, first: 50, after: $after, orderBy: { field: CREATED_AT, direction: ASC }) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id number authorAssociation author { __typename login }
              #{details}
              projectItems(first: 20) {
                nodes {
                  id project { id }
                  status: fieldValueByName(name: "#{ProjectBoard::STATUS_FIELD}") {
                    ... on ProjectV2ItemFieldSingleSelectValue { name updatedAt }
                  }
                  next: fieldValueByName(name: "#{ProjectBoard::NEXT_STEP_FIELD}") {
                    ... on ProjectV2ItemFieldTextValue { updatedAt }
                  }
                }
              }
            }
          }
        }
      }
    GRAPHQL
  end

  def rest(method, path, **body)
    environment = { 'GH_TOKEN' => @environment['TRIAGE_PROJECT_TOKEN'], 'GITHUB_TOKEN' => nil }
    _output, _errors, status = Open3.capture3(environment, 'gh', 'api', '--method', method, path, '--input', '-',
                                              stdin_data: JSON.generate(body))
    report("GitHub refused #{method} #{path}.") unless status.success?
  end

  def default_branch
    @default_branch ||= begin
      owner, name = @repository.split('/', 2)
      @board.graphql('query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) ' \
                     '{ defaultBranchRef { name } } }', owner: owner, name: name)
            .dig('data', 'repository', 'defaultBranchRef', 'name') || 'main'
    end
  end

  def bug?(issue)
    issue.dig('labels', 'nodes').to_a.any? { |label| label['name'] == 'bug' }
  end

  def maintainer?(node)
    TriageEvent.maintainer?(node['authorAssociation'])
  end

  def dry_run?
    @environment['TRIAGE_DRY_RUN'] == 'true'
  end

  def report(message)
    puts message
    summary = @environment['GITHUB_STEP_SUMMARY']
    File.open(summary, 'a') { |file| file.puts("#{message}\n\n") } if summary
  end
end

if $PROGRAM_NAME == __FILE__
  if ENV['TRIAGE_PROJECT_TOKEN'].to_s.empty?
    puts 'Skipped: no project-token is set.'
    exit 0
  end

  succeeded = begin
    BoardSweep.new.run
  rescue ProjectBoard::Error => e
    puts "Failed: #{e.message}."
    false
  end
  exit(succeeded ? 0 : 1)
end
