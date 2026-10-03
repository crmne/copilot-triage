# frozen_string_literal: true

require 'json'
require 'open3'
require 'time'
require 'yaml'
require_relative 'board_rules'
require_relative 'triage_policy'
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
  # The maintainer's review is requested while a pull request waits on them.
  REVIEW_COLUMNS = %w[sign_off do].freeze

  def initialize(environment = ENV)
    @environment = environment
    @repository = environment.fetch('GITHUB_REPOSITORY')
    config = TriagePolicy.load(environment.fetch('TRIAGE_CONFIG', '.github/triage.yml'),
                               token: environment['GH_TOKEN'] || environment['TRIAGE_PROJECT_TOKEN'])
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
    @pull_columns = {}
    # Pull requests first, so an issue can follow the card of its fix.
    %w[pullRequests issues].each do |connection|
      each_open(connection) do |node|
        break if @changes >= MAX_CHANGES

        sweep(connection, node)
      end
    end
    finish_work
    watch_default_branch
    report("Board sweep: #{@changes} change#{'s' unless @changes == 1}#{' proposed' if dry_run?}.")
    report("Stopped at #{MAX_CHANGES} changes; the next run continues.") if @changes >= MAX_CHANGES
    true
  rescue ProjectBoard::Error => e
    report("Failed: #{e.message}.")
    false
  end

  private

  def sweep(connection, node)
    item = node.dig('projectItems', 'nodes').find { |entry| entry.dig('project', 'id') == @board.id }
    status = item&.fetch('status', nil)
    current = @board.column_key(status&.fetch('name', nil))
    pull = connection == 'pullRequests'
    updated_at = status&.fetch('updatedAt', nil)
    finished = item && (item['isArchived'] || current == 'done')
    # An open item in Done was put there by hand, or was closed and archived:
    # it stays done until it is reopened or someone comments.
    return dismiss(node, item) if finished && !BoardRules.revived?(node, updated_at)

    current = nil if finished
    column = if pull then BoardRules.pull_request_column(node)
             else BoardRules.issue_column(node, current, updated_at, linked_column: linked_column(node))
             end
    if column == :agent
      judge(node, item) unless dry_run?
      column = current || 'do'
    end
    movable = pull ? PULL_REQUEST_MOVABLE : ProjectBoard::MOVABLE
    # A pull request parked for a scope decision still goes back to its author
    # when it stops being mergeable.
    movable += ['decide'] if pull && column == 'theirs'
    final = item && (column.nil? || column == current || !movable.include?(current)) ? current : column
    @pull_columns[node.fetch('number')] = final if pull
    move(node, item, current, final, pull) unless item && final == current
    keep_review_request(node, final) if pull
  end

  def dismiss(node, item)
    return if item['isArchived']

    report("##{node.fetch('number')}: done by hand, archived")
    @board.archive(item.fetch('id')) unless dry_run?
  end

  def linked_column(issue)
    issue.dig('closedByPullRequestsReferences', 'nodes').to_a.filter_map { |pull| @pull_columns[pull['number']] }.first
  end

  # A "needs a closer look" verdict, or another review bot's findings, is the
  # agent's call. Triage runs on bot reviews of same-repository pull requests;
  # for forks, whose review runs get no secrets, the sweep dispatches the triage
  # workflow, once per review: a next step written after the latest review
  # means it was already judged.
  def judge(pull, item)
    reviewed = BoardRules.reviewed_at(pull)
    judged = item&.dig('next', 'updatedAt')
    return if judged && reviewed && judged > reviewed

    workflow = @environment.fetch('TRIAGE_WORKFLOW', 'triage.yml')
    report("PR ##{pull.fetch('number')}: a review bot asks for judgment; sending it to #{workflow}")
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

    # add brings an archived card back before it is placed.
    target = item.nil? || item['isArchived'] ? @board.add(node.fetch('id')) : item
    @board.set_column(target.fetch('id'), column)
    step = BoardRules.reason(node, column, pull:)
    @board.set_next_step(target.fetch('id'), step) if step
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

    input = if wanted then CopilotReview.request_input(pull.fetch('id'), @maintainer)
            else CopilotReview.withdraw_input(pull, pull.fetch('id'), @maintainer)
            end
    repository_graphql(CopilotReview::REQUEST_MUTATION, input: input) if input
  end

  # Closed issues and closed or merged pull requests go to Done, and leave the
  # board at the first sweep after archive_after_days there (0 by default, so
  # Done shows what finished since the last sweep).
  def finish_work
    owner, name = @repository.split('/', 2)
    card = 'nodes { number projectItems(first: 20, includeArchived: false) { nodes { id project { id } ' \
           "status: fieldValueByName(name: \"#{ProjectBoard::STATUS_FIELD}\") " \
           '{ ... on ProjectV2ItemFieldSingleSelectValue { name updatedAt } } } } }'
    query = <<~GRAPHQL
      query($owner: String!, $name: String!) {
        repository(owner: $owner, name: $name) {
          issues(states: CLOSED, last: 100, orderBy: { field: UPDATED_AT, direction: ASC }) { #{card} }
          pullRequests(states: [CLOSED, MERGED], last: 100, orderBy: { field: UPDATED_AT, direction: ASC }) { #{card} }
        }
      }
    GRAPHQL
    repository = @board.graphql(query, owner: owner, name: name).fetch('data').fetch('repository')
    cutoff = (Time.now.utc - (@board.archive_after * 86_400)).iso8601
    (repository.dig('issues', 'nodes') + repository.dig('pullRequests', 'nodes')).each do |node|
      item = node.dig('projectItems', 'nodes').find { |entry| entry.dig('project', 'id') == @board.id }
      next unless item

      finish(node, item, cutoff)
    end
  end

  def finish(node, item, cutoff)
    status = item['status'] || {}
    if @board.column_key(status['name']) != 'done'
      report("##{node.fetch('number')}: finished, to #{@board.column_name('done')}")
      @board.set_column(item.fetch('id'), 'done') unless dry_run?
    elsif status['updatedAt'].to_s <= cutoff
      report("##{node.fetch('number')}: done, archived")
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
                'stateReason labels(first: 20) { nodes { name } } ' \
                  'closedByPullRequestsReferences(first: 3, includeClosedPrs: false) { totalCount nodes { number } }'
              else
                "isDraft mergeable reviewDecision #{CopilotReview::FIELDS} " \
                  'commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first: 100) { nodes { ' \
                  '... on CheckRun { name conclusion } ... on StatusContext { context state } } } } } } }'
              end
    <<~GRAPHQL
      query($owner: String!, $name: String!, $after: String) {
        repository(owner: $owner, name: $name) {
          #{connection}(states: OPEN, first: 50, after: $after, orderBy: { field: CREATED_AT, direction: ASC }) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id number authorAssociation author { __typename login }
              comments(last: 5) { nodes { createdAt authorAssociation author { __typename login } } }
              reopened: timelineItems(itemTypes: [REOPENED_EVENT], last: 1) { nodes { ... on ReopenedEvent { createdAt } } }
              #{details}
              projectItems(first: 20) {
                nodes {
                  id isArchived project { id }
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

  # Actions on a repository, such as review requests and dispatches, come from
  # the workflow's own token, so they appear as the bot rather than the
  # maintainer; the project token only reaches the board.
  def repository_token
    token = @environment['GH_TOKEN'].to_s
    token.empty? ? @environment['TRIAGE_PROJECT_TOKEN'] : token
  end

  def repository_graphql(query, **variables)
    _output, _errors, status = Open3.capture3({ 'GH_TOKEN' => repository_token, 'GITHUB_TOKEN' => nil },
                                              'gh', 'api', 'graphql', '--input', '-',
                                              stdin_data: JSON.generate(query: query, variables: variables))
    report('GitHub refused a review request change.') unless status.success?
  end

  def rest(method, path, **body)
    environment = { 'GH_TOKEN' => repository_token, 'GITHUB_TOKEN' => nil }
    _output, _errors, status = Open3.capture3(environment, 'gh', 'api', '--method', method, path, '--input', '-',
                                              stdin_data: JSON.generate(body))
    report("GitHub refused #{method} #{path}.") unless status.success?
  end

  def default_branch
    branch_state.fetch('name')
  end

  def branch_state
    @branch_state ||= begin
      owner, name = @repository.split('/', 2)
      ref = @board.graphql('query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) ' \
                           '{ defaultBranchRef { name target { ... on Commit { statusCheckRollup { state } } } } } }',
                           owner: owner, name: name).dig('data', 'repository', 'defaultBranchRef') || {}
      { 'name' => ref['name'] || 'main', 'checks' => ref.dig('target', 'statusCheckRollup', 'state') }
    end
  end

  # A failing default branch makes every pull request look broken, so it gets
  # an urgent card of its own in Do until it passes again.
  def watch_default_branch
    title = "#{default_branch} is failing in #{@repository}"
    failing = %w[FAILURE ERROR].include?(branch_state['checks'])
    card = @board.drafts[title]
    if failing && !card
      report("#{title}: urgent card added")
      unless dry_run?
        @board.add_draft(title, body: 'Every pull request inherits these failures until the default branch passes.',
                                column: 'do', priority: 'urgent',
                                next_step: "Fix the failing checks on #{default_branch} first")
      end
    elsif !failing && card
      report("#{title.sub('is failing', 'passes again')}: card archived")
      @board.archive(card) unless dry_run?
    end
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
