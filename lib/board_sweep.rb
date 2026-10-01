# frozen_string_literal: true

require 'json'
require 'yaml'
require_relative 'project_board'
require_relative 'triage_event'

# Scheduled, model-free board upkeep for one repository: adds open issues and pull
# requests that are not on the board yet and applies moves that follow from GitHub
# facts (who spoke last, linked pull requests, review and check state).
class BoardSweep
  MAX_CHANGES = 100
  # Pull request cards in In progress move once the facts change, e.g. a draft
  # becoming ready. Issue cards in In progress stay where the maintainer put them.
  PULL_REQUEST_MOVABLE = (ProjectBoard::MOVABLE + ['in_progress']).freeze

  def initialize(environment = ENV)
    @environment = environment
    @repository = environment.fetch('GITHUB_REPOSITORY')
    config = YAML.safe_load_file(environment.fetch('TRIAGE_CONFIG', '.github/triage.yml'))
    settings = config['board'] or raise ProjectBoard::Error, 'the sweep needs a board section in the triage policy'
    @board = ProjectBoard.new(settings, token: environment['TRIAGE_PROJECT_TOKEN'])
    @changes = 0
  end

  def run
    %w[issues pullRequests].each do |connection|
      each_open(connection) do |node|
        break if @changes >= MAX_CHANGES

        sweep(connection, node)
      end
    end
    report("Board sweep: #{@changes} change#{'s' unless @changes == 1}#{' proposed' if dry_run?}.")
    report("Stopped at #{MAX_CHANGES} changes; the next run continues.") if @changes >= MAX_CHANGES
    true
  rescue ProjectBoard::Error => e
    report("Failed: #{e.message}.")
    false
  end

  def issue_column(issue, current, status_updated_at)
    return 'in_progress' if issue.dig('closedByPullRequestsReferences', 'totalCount').to_i.positive?

    human = issue.dig('comments', 'nodes').reject { |comment| TriageEvent.bot?(comment['author']) }.last
    if current.nil?
      return 'backlog' if maintainer?(issue) && (human.nil? || maintainer?(human))

      return human && maintainer?(human) ? 'waiting_on_reporter' : 'needs_maintainer'
    end
    return unless current == 'waiting_on_reporter' && human && !maintainer?(human)

    'needs_maintainer' if status_updated_at.nil? || human.fetch('createdAt') > status_updated_at
  end

  def pull_request_column(pull)
    return 'in_progress' if pull['isDraft']

    own = maintainer?(pull)
    checks = pull.dig('commits', 'nodes', 0, 'commit', 'statusCheckRollup', 'state')
    blocked = %w[FAILURE ERROR].include?(checks) || pull['mergeable'] == 'CONFLICTING' ||
              (!own && pull['reviewDecision'] == 'CHANGES_REQUESTED')
    return own ? 'in_progress' : 'waiting_on_reporter' if blocked

    approved = pull['reviewDecision'] == 'APPROVED' || (own && pull['reviewDecision'].nil?)
    return 'ready_to_merge' if approved && [nil, 'SUCCESS'].include?(checks) && pull['mergeable'] == 'MERGEABLE'

    own ? 'in_progress' : 'needs_maintainer'
  end

  private

  def sweep(connection, node)
    item = node.dig('projectItems', 'nodes').find { |entry| entry.dig('project', 'id') == @board.id }
    status = item&.fetch('status', nil)
    current = @board.column_key(status&.fetch('name', nil))
    pull = connection == 'pullRequests'
    column = pull ? pull_request_column(node) : issue_column(node, current, status&.fetch('updatedAt', nil))
    movable = pull ? PULL_REQUEST_MOVABLE : ProjectBoard::MOVABLE
    return if item && (column.nil? || column == current || !movable.include?(current))

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
                'comments(last: 5) { nodes { createdAt authorAssociation author { __typename login } } } ' \
                  'closedByPullRequestsReferences(first: 1, includeClosedPrs: false) { totalCount }'
              else
                'isDraft mergeable reviewDecision commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }'
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
                }
              }
            }
          }
        }
      }
    GRAPHQL
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
  succeeded = begin
    BoardSweep.new.run
  rescue ProjectBoard::Error => e
    puts "Failed: #{e.message}."
    false
  end
  exit(succeeded ? 0 : 1)
end
