# frozen_string_literal: true

require_relative '../lib/board_sweep'

RSpec.describe BoardSweep do
  let(:environment) do
    { 'GITHUB_REPOSITORY' => 'crmne/spotifast', 'TRIAGE_CONFIG' => 'board.yml', 'TRIAGE_PROJECT_TOKEN' => 'token',
      'TRIAGE_WORKFLOW' => 'issue-assessment.yml' }
  end
  let(:settings) { { 'project' => 'https://github.com/users/crmne/projects/1', 'maintainer' => 'crmne' } }
  # archive_after comes from the real board; ProjectBoard is partially stubbed below.
  let(:sweep) { described_class.new(environment) }
  let(:board) { sweep.instance_variable_get(:@board) }
  let(:issues) { [] }
  let(:pulls) { [] }
  let(:finished) { { 'issues' => [], 'pullRequests' => [] } }
  let(:moves) { [] }
  let(:archived) { [] }
  let(:requests) { [] }

  def comment(association, created_at = '2026-09-02T00:00:00Z', login: 'someone')
    { 'createdAt' => created_at, 'authorAssociation' => association, 'author' => { 'login' => login } }
  end

  def card(number, status, updated_at: nil, next_at: nil)
    [{ 'id' => "item-#{number}", 'project' => { 'id' => 'project-id' },
       'status' => status && { 'name' => status, 'updatedAt' => updated_at },
       'next' => next_at && { 'updatedAt' => next_at } }]
  end

  def issue(number, association: 'NONE', comments: [], linked: 0, labels: [], status: nil, updated_at: nil,
            on_board: !status.nil?)
    { 'id' => "issue-#{number}", 'number' => number, 'authorAssociation' => association,
      'labels' => { 'nodes' => labels.map { |name| { 'name' => name } } },
      'comments' => { 'nodes' => comments }, 'closedByPullRequestsReferences' => { 'totalCount' => linked },
      'projectItems' => { 'nodes' => on_board ? card(number, status, updated_at: updated_at) : [] } }
  end

  def copilot(verdict, commit: 'head', submitted_at: '2026-10-01T10:00:00Z')
    icon = { approve: '🟢 Approval recommended', changes: '🟡 Changes recommended',
             closer: '🔵 Needs a closer look' }.fetch(verdict)
    { 'author' => { 'login' => 'copilot-pull-request-reviewer' }, 'state' => 'COMMENTED',
      'body' => "## Copilot review overview\n\n### #{icon}\n\nReason.", 'submittedAt' => submitted_at,
      'commit' => { 'oid' => commit } }
  end

  def pull(number, status: nil, next_at: nil, **facts)
    checks = facts.key?(:checks) ? facts[:checks] : 'SUCCESS'
    requested = Array(facts[:requested]).map { |login| { 'requestedReviewer' => { 'login' => login } } }
    { 'id' => "pr-#{number}", 'number' => number, 'authorAssociation' => facts.fetch(:association, 'CONTRIBUTOR'),
      'author' => { 'login' => facts.fetch(:author, 'contributor') }, 'headRefOid' => 'head',
      'isDraft' => facts.fetch(:draft, false), 'mergeable' => facts.fetch(:mergeable, 'MERGEABLE'),
      'reviewDecision' => facts[:review], 'reviewRequests' => { 'nodes' => requested },
      'reviews' => { 'nodes' => [facts[:copilot]].compact },
      'commits' => { 'nodes' => [{ 'commit' => { 'statusCheckRollup' => checks && { 'state' => checks } } }] },
      'projectItems' => { 'nodes' => status ? card(number, status, next_at: next_at) : [] } }
  end

  before do
    File.write('board.yml', YAML.dump('board' => settings))
    allow(sweep).to receive(:puts)
    allow(sweep).to receive(:rest) { |method, path, **body| requests << [method, path, body] }
    allow(board).to receive_messages(id: 'project-id', set_up: [], ensure_repository_view: nil)
    allow(board).to receive(:add) { |content| { 'id' => "new-#{content}" } }
    allow(board).to receive(:set_column) { |item, column| moves << [item, column] }
    allow(board).to receive(:archive) { |item| archived << item }
    allow(board).to receive(:graphql) do |query, **|
      if query.include?('defaultBranchRef')
        { 'data' => { 'repository' => { 'defaultBranchRef' => { 'name' => 'main' } } } }
      elsif query.include?('states: CLOSED')
        { 'data' => { 'repository' => finished.transform_values { |nodes| { 'nodes' => nodes } } } }
      else
        connection = query.include?('pullRequests(') ? 'pullRequests' : 'issues'
        nodes = connection == 'issues' ? issues : pulls
        { 'data' => { 'repository' => { connection => { 'pageInfo' => { 'hasNextPage' => false },
                                                        'nodes' => nodes } } } }
      end
    end
  end

  it 'sets the project up before sweeping' do
    sweep.run
    expect(board).to have_received(:set_up)
  end

  it 'places new issues: answers and decisions, bugs to fix, waits, and your own notes' do
    issues.push(issue(1), issue(2, comments: [comment('OWNER', login: 'crmne')]), issue(3, labels: ['bug']),
                issue(4, association: 'OWNER'), issue(5, linked: 1),
                issue(6, comments: [comment('OWNER'), comment('NONE', login: 'github-actions[bot]')]))

    expect(sweep.run).to be(true)
    expect(moves).to eq([%w[new-issue-1 decide], %w[new-issue-2 waiting], %w[new-issue-3 fix],
                         %w[new-issue-4 backlog], %w[new-issue-5 waiting], %w[new-issue-6 waiting]])
  end

  it 'brings a waiting issue back when the reporter answered after it moved' do
    issues.push(issue(1, status: 'Waiting on others', updated_at: '2026-09-01T00:00:00Z', comments: [comment('NONE')]),
                issue(2, status: 'Waiting on others', updated_at: '2026-09-03T00:00:00Z', comments: [comment('NONE')]),
                issue(3, status: 'Waiting on others', updated_at: '2026-09-01T00:00:00Z', labels: ['bug'],
                         comments: [comment('NONE')]),
                issue(4, status: 'Answer or decide', comments: [comment('OWNER')]))

    sweep.run
    expect(moves).to eq([%w[item-1 decide], %w[item-3 fix]])
  end

  it 'never moves cards out of the backlog or a column of the maintainer own' do
    issues.push(issue(1, status: 'Backlog', linked: 1), issue(2, status: 'Someday', comments: [comment('NONE')]),
                issue(3, status: 'Answer or decide', linked: 1))

    sweep.run
    expect(moves).to eq([%w[item-3 waiting]])
  end

  it 'gives a card without a column one, such as after retired columns are removed' do
    issues.push(issue(1, on_board: true))

    sweep.run
    expect(moves).to eq([%w[item-1 decide]])
  end

  describe 'pull requests' do
    it 'follows Copilot on the latest commit, checks, and reviews' do
      pulls.push(pull(1, copilot: copilot(:approve)), pull(2, copilot: copilot(:changes)),
                 pull(3, review: 'APPROVED'), pull(4), pull(5, draft: true), pull(6, checks: 'FAILURE'),
                 pull(7, checks: 'PENDING'), pull(8, requested: 'copilot-pull-request-reviewer'),
                 pull(9, copilot: copilot(:approve, commit: 'older')), pull(10, mergeable: 'CONFLICTING'))

      sweep.run
      expect(moves.map(&:last)).to eq(%w[approve waiting approve review waiting waiting waiting waiting review
                                         waiting])
    end

    it 'treats the maintainer own pull requests as work to finish or merge' do
      pulls.push(pull(1, association: 'OWNER', author: 'crmne'),
                 pull(2, association: 'OWNER', author: 'crmne', copilot: copilot(:changes)),
                 pull(3, association: 'OWNER', author: 'crmne', draft: true))

      sweep.run
      expect(moves.map(&:last)).to eq(%w[approve fix fix])
    end

    it 'leaves a closer look to the agent and sends an unjudged review to triage once' do
      pulls.push(pull(1, copilot: copilot(:closer)),
                 pull(2, status: 'Approve', copilot: copilot(:closer), next_at: '2026-10-01T09:00:00Z'),
                 pull(3, status: 'Approve', copilot: copilot(:closer), next_at: '2026-10-01T11:00:00Z'))

      sweep.run
      expect(moves).to eq([%w[new-pr-1 review]])
      dispatched = requests.select { |_, path, _| path.end_with?('/dispatches') }
      expect(dispatched.map { |_, _, body| body.dig(:inputs, :number) }).to eq(%w[1 2])
      expect(dispatched.first).to eq(['POST', 'repos/crmne/spotifast/actions/workflows/issue-assessment.yml/dispatches',
                                      { ref: 'main', inputs: { kind: 'pull_request', number: '1', dry_run: 'false' } }])
    end

    it 'keeps a question the agent put to the maintainer' do
      pulls.push(pull(1, status: 'Answer or decide', copilot: copilot(:approve)))

      sweep.run
      expect(moves).to be_empty
    end

    it 'requests the maintainer review in Approve and Review and withdraws it elsewhere' do
      pulls.push(pull(1, copilot: copilot(:approve)), pull(2, status: 'Waiting on others', requested: 'crmne',
                                                              copilot: copilot(:changes)),
                 pull(3, status: 'Review', requested: 'crmne'),
                 pull(4, association: 'OWNER', author: 'crmne'))

      sweep.run
      reviewers = requests.reject { |_, path, _| path.end_with?('/dispatches') }
      expect(reviewers).to eq([['POST', 'repos/crmne/spotifast/pulls/1/requested_reviewers', { reviewers: ['crmne'] }],
                               ['DELETE', 'repos/crmne/spotifast/pulls/2/requested_reviewers',
                                { reviewers: ['crmne'] }]])
    end
  end

  it 'moves finished work to Done and archives it after a week there' do
    old = (Time.now.utc - (8 * 86_400)).iso8601
    recent = (Time.now.utc - 86_400).iso8601
    finished['issues'] = [{ 'number' => 1, 'projectItems' => { 'nodes' => card(1, 'Fix') } },
                          { 'number' => 2, 'projectItems' => { 'nodes' => [] } },
                          { 'number' => 4, 'projectItems' => { 'nodes' => card(4, 'Done', updated_at: old) } }]
    finished['pullRequests'] = [{ 'number' => 3, 'projectItems' => { 'nodes' => card(3, 'Approve') } },
                                { 'number' => 5, 'projectItems' => { 'nodes' => card(5, 'Done', updated_at: recent) } }]

    sweep.run
    expect(moves).to eq([%w[item-1 done], %w[item-3 done]])
    expect(archived).to eq(%w[item-4])
  end

  it 'places a reopened card again, bringing it back from the archive' do
    archived_card = issue(2, status: 'Done')
    archived_card['projectItems']['nodes'].first['isArchived'] = true
    issues.push(issue(1, status: 'Done', labels: ['bug']), archived_card)

    sweep.run
    expect(moves).to eq([%w[item-1 fix], %w[new-issue-2 decide]])
    expect(board).to have_received(:add).with('issue-2')
  end

  it 'adds a board view for the repository once it has cards' do
    issues.push(issue(1))

    sweep.run
    expect(board).to have_received(:ensure_repository_view).with('crmne/spotifast')
  end

  it 'only reports proposed changes in a dry run' do
    environment['TRIAGE_DRY_RUN'] = 'true'
    issues.push(issue(1))
    finished['issues'] =
      [{ 'number' => 9, 'projectItems' => { 'nodes' => card(9, 'Done', updated_at: '2026-01-01T00:00:00Z') } }]

    sweep.run
    expect(moves).to be_empty
    expect(archived).to be_empty
    expect(board).not_to have_received(:set_up)
    expect(sweep).to have_received(:puts).with('#1: new card to Answer or decide')
    expect(sweep).to have_received(:puts).with('Board sweep: 1 change proposed.')
  end

  it 'stops after a bounded number of changes' do
    issues.concat((1..(described_class::MAX_CHANGES + 5)).map { |number| issue(number) })
    pulls.push(pull(1))

    sweep.run
    expect(moves.size).to eq(described_class::MAX_CHANGES)
    expect(sweep).to have_received(:puts).with(/Stopped at #{described_class::MAX_CHANGES} changes/)
  end

  it 'fails without a board section' do
    File.write('board.yml', YAML.dump('labels' => {}))

    expect { described_class.new(environment) }.to raise_error(ProjectBoard::Error, /board section/)
  end
end
