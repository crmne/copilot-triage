# frozen_string_literal: true

require_relative '../lib/board_sweep'

RSpec.describe BoardSweep do
  let(:environment) do
    { 'GITHUB_REPOSITORY' => 'crmne/spotifast', 'TRIAGE_CONFIG' => 'board.yml', 'TRIAGE_PROJECT_TOKEN' => 'token' }
  end
  let(:sweep) { described_class.new(environment) }
  let(:board) { sweep.instance_variable_get(:@board) }
  let(:issues) { [] }
  let(:pulls) { [] }
  let(:moves) { [] }

  def comment(association, created_at = '2026-09-02T00:00:00Z', login: 'someone')
    { 'createdAt' => created_at, 'authorAssociation' => association, 'author' => { 'login' => login } }
  end

  def issue(number, association: 'NONE', comments: [], linked: 0, status: nil, updated_at: nil, on_board: !status.nil?)
    items = if on_board
              [{ 'id' => "item-#{number}", 'project' => { 'id' => 'project-id' },
                 'status' => status && { 'name' => status, 'updatedAt' => updated_at } }]
            else
              []
            end
    { 'id' => "issue-#{number}", 'number' => number, 'authorAssociation' => association,
      'comments' => { 'nodes' => comments }, 'closedByPullRequestsReferences' => { 'totalCount' => linked },
      'projectItems' => { 'nodes' => items } }
  end

  def pull(number, status: nil, **facts)
    items = if status
              [{ 'id' => "item-pr-#{number}", 'project' => { 'id' => 'project-id' },
                 'status' => { 'name' => status } }]
            else
              []
            end
    checks = facts.key?(:checks) ? facts[:checks] : 'SUCCESS'
    { 'id' => "pr-#{number}", 'number' => number, 'authorAssociation' => facts.fetch(:association, 'CONTRIBUTOR'),
      'isDraft' => facts.fetch(:draft, false), 'mergeable' => facts.fetch(:mergeable, 'MERGEABLE'),
      'reviewDecision' => facts[:review],
      'commits' => { 'nodes' => [{ 'commit' => { 'statusCheckRollup' => checks && { 'state' => checks } } }] },
      'projectItems' => { 'nodes' => items } }
  end

  before do
    File.write('board.yml', YAML.dump('board' => { 'project' => 'https://github.com/users/crmne/projects/3' }))
    allow(sweep).to receive(:puts)
    allow(board).to receive_messages(id: 'project-id')
    allow(board).to receive(:add) { |content| { 'id' => "new-#{content}" } }
    allow(board).to receive(:set_column) { |item, column| moves << [item, column] }
    allow(board).to receive(:graphql) do |query, **|
      connection = query.include?('pullRequests(') ? 'pullRequests' : 'issues'
      nodes = connection == 'issues' ? issues : pulls
      { 'data' => { 'repository' => { connection => { 'pageInfo' => { 'hasNextPage' => false }, 'nodes' => nodes } } } }
    end
  end

  it 'adds open issues by who spoke last' do
    issues.push(issue(1), issue(2, comments: [comment('OWNER', login: 'crmne')]),
                issue(3, comments: [comment('OWNER'), comment('NONE')]),
                issue(4, association: 'OWNER'), issue(5, linked: 1),
                issue(6, comments: [comment('OWNER'), comment('NONE', login: 'github-actions[bot]')]))

    expect(sweep.run).to be(true)
    expect(moves).to eq([%w[new-issue-1 needs_maintainer], %w[new-issue-2 waiting_on_reporter],
                         %w[new-issue-3 needs_maintainer], %w[new-issue-4 backlog], %w[new-issue-5 in_progress],
                         %w[new-issue-6 waiting_on_reporter]])
  end

  it 'moves a waiting card back when the reporter answered after it moved' do
    issues.push(issue(1, status: 'Waiting on them', updated_at: '2026-09-01T00:00:00Z', comments: [comment('NONE')]),
                issue(2, status: 'Waiting on them', updated_at: '2026-09-03T00:00:00Z', comments: [comment('NONE')]),
                issue(3, status: 'Needs me', comments: [comment('OWNER')]))

    sweep.run
    expect(moves).to eq([%w[item-1 needs_maintainer]])
  end

  it 'never moves issue cards out of maintainer columns' do
    issues.push(issue(1, status: 'Backlog', linked: 1), issue(2, status: 'Blocked', comments: [comment('NONE')]),
                issue(3, status: 'In progress', linked: 1), issue(4, status: 'Needs me', linked: 1))

    sweep.run
    expect(moves).to eq([%w[item-4 in_progress]])
  end

  it 'gives an existing card without a column one' do
    issues.push(issue(1, on_board: true))

    sweep.run
    expect(moves).to eq([%w[item-1 needs_maintainer]])
  end

  it 'places pull requests from review and check state' do
    pulls.push(pull(1, review: 'APPROVED'), pull(2), pull(3, draft: true), pull(4, checks: 'FAILURE'),
               pull(5, review: 'CHANGES_REQUESTED'), pull(6, association: 'OWNER'),
               pull(7, association: 'OWNER', checks: 'PENDING'),
               pull(8, association: 'OWNER', mergeable: 'CONFLICTING'),
               pull(9, review: 'APPROVED', checks: nil), pull(10, review: 'APPROVED', mergeable: 'UNKNOWN'))

    sweep.run
    expect(moves.map(&:last)).to eq(%w[ready_to_merge needs_maintainer in_progress waiting_on_reporter
                                       waiting_on_reporter ready_to_merge in_progress in_progress ready_to_merge
                                       needs_maintainer])
  end

  it 'moves a pull request out of In progress once it is ready, but not out of Blocked' do
    pulls.push(pull(1, status: 'In progress', review: 'APPROVED'), pull(2, status: 'Blocked', review: 'APPROVED'),
               pull(3, status: 'Ready to merge', review: 'APPROVED'))

    sweep.run
    expect(moves).to eq([%w[item-pr-1 ready_to_merge]])
  end

  it 'only reports proposed changes in a dry run' do
    environment['TRIAGE_DRY_RUN'] = 'true'
    issues.push(issue(1))

    sweep.run
    expect(moves).to be_empty
    expect(board).not_to have_received(:add)
    expect(sweep).to have_received(:puts).with('#1: new card to Needs me')
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
