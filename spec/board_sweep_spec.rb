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
  let(:review_requests) { [] }
  let(:drafts) { {} }
  let(:steps) { [] }
  let(:main_checks) { +'SUCCESS' }

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
    requested = Array(facts[:requested]).map do |login|
      type = login.start_with?('copilot') ? 'Bot' : 'User'
      { 'requestedReviewer' => { '__typename' => type, 'login' => login } }
    end
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
    allow(sweep).to receive(:repository_graphql) { |_query, **variables| review_requests << variables.fetch(:input) }
    allow(board).to receive_messages(id: 'project-id', set_up: [], drafts: drafts)
    allow(board).to receive(:add_draft)
    allow(board).to receive(:add) { |content| { 'id' => "new-#{content}" } }
    allow(board).to receive(:set_column) { |item, column| moves << [item, column] }
    allow(board).to receive(:set_next_step) { |item, text| steps << [item, text] }
    allow(board).to receive(:archive) { |item| archived << item }
    allow(board).to receive(:graphql) do |query, **_variables|
      if query.include?('defaultBranchRef')
        { 'data' => { 'repository' => { 'defaultBranchRef' => {
          'name' => 'main', 'target' => { 'statusCheckRollup' => { 'state' => main_checks } }
        } } } }
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
    expect(moves).to eq([%w[new-issue-1 decide], %w[new-issue-2 theirs], %w[new-issue-3 do],
                         %w[new-issue-4 not_now], %w[new-issue-5 theirs], %w[new-issue-6 theirs]])
  end

  it 'brings a waiting issue back when the reporter answered after it moved' do
    issues.push(issue(1, status: 'Their move', updated_at: '2026-09-01T00:00:00Z', comments: [comment('NONE')]),
                issue(2, status: 'Their move', updated_at: '2026-09-03T00:00:00Z', comments: [comment('NONE')]),
                issue(3, status: 'Their move', updated_at: '2026-09-01T00:00:00Z', labels: ['bug'],
                         comments: [comment('NONE')]),
                issue(4, status: 'Decide', comments: [comment('OWNER')]))

    sweep.run
    expect(moves).to eq([%w[item-1 decide], %w[item-3 do]])
  end

  it 'never moves cards out of Not now or a column of the maintainer own' do
    issues.push(issue(1, status: 'Not now', linked: 1), issue(2, status: 'Someday', comments: [comment('NONE')]),
                issue(3, status: 'Decide', linked: 1))

    sweep.run
    expect(moves).to eq([%w[item-3 theirs]])
  end

  it 'moves an issue with the pull request that would close it' do
    pulls.push(pull(7, copilot: copilot(:approve)))
    linked = issue(1, linked: 1)
    linked['closedByPullRequestsReferences']['nodes'] = [{ 'number' => 7 }]
    issues.push(linked)

    sweep.run
    expect(moves).to eq([%w[new-pr-7 sign_off], %w[new-issue-1 sign_off]])
  end

  it 'adds an urgent card while the default branch fails, and archives it once it passes' do
    main_checks.replace('FAILURE')
    sweep.run
    expect(board).to have_received(:add_draft)
      .with('main is failing in crmne/spotifast', hash_including(column: 'do', priority: 'urgent'))

    main_checks.replace('SUCCESS')
    drafts['main is failing in crmne/spotifast'] = 'draft-item'
    sweep.run
    expect(archived).to eq(['draft-item'])
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
      expect(moves.map(&:last)).to eq(%w[sign_off theirs sign_off do theirs theirs theirs theirs do theirs])
    end

    it 'sends a pull request with CodeRabbit findings on the latest commit to the agent, once per review' do
      rabbit = { 'author' => { 'login' => 'coderabbitai' }, 'state' => 'COMMENTED', 'commit' => { 'oid' => 'head' },
                 'submittedAt' => '2026-10-02T10:00:00Z' }
      pulls.push(pull(1, copilot: rabbit), pull(2, status: 'Do', copilot: rabbit, next_at: '2026-10-02T11:00:00Z'),
                 pull(3, association: 'OWNER', author: 'crmne', copilot: rabbit))

      sweep.run
      expect(moves).to eq([%w[new-pr-1 do], %w[new-pr-3 sign_off]])
      dispatched = requests.select { |_, path, _| path.end_with?('/dispatches') }
      expect(dispatched.map { |_, _, body| body.dig(:inputs, :number) }).to eq(%w[1])
    end

    it "ignores triage's own jobs and cancelled runs in the checks" do
      rollup = lambda do |*checks|
        { 'state' => 'FAILURE', 'contexts' => { 'nodes' => checks.map do |name, conclusion|
          { 'name' => name, 'conclusion' => conclusion }
        end } }
      end
      clean = pull(1, review: 'APPROVED')
      clean['commits']['nodes'][0]['commit']['statusCheckRollup'] = rollup.call(%w[test SUCCESS], %w[assess CANCELLED],
                                                                                %w[lint CANCELLED])
      broken = pull(2, review: 'APPROVED')
      broken['commits']['nodes'][0]['commit']['statusCheckRollup'] = rollup.call(%w[test FAILURE])
      pulls.push(clean, broken)

      sweep.run
      expect(moves.map(&:last)).to eq(%w[sign_off theirs])
    end

    it 'gives a pull request back to the maintainer once its author pushed after changes were requested' do
      asked = lambda do |commit|
        { 'author' => { 'login' => 'crmne' }, 'state' => 'CHANGES_REQUESTED', 'commit' => { 'oid' => commit } }
      end
      pulls.push(pull(1, review: 'CHANGES_REQUESTED', copilot: asked.call('older')),
                 pull(2, review: 'CHANGES_REQUESTED', copilot: asked.call('head')))

      sweep.run
      expect(moves.map(&:last)).to eq(%w[do theirs])
    end

    it "sends CodeRabbit's requested changes to the agent, and takes its approval of a ready pull request" do
      rabbit = lambda { |state|
        { 'author' => { 'login' => 'coderabbitai' }, 'state' => state, 'commit' => { 'oid' => 'head' } }
      }
      pulls.push(pull(1, copilot: rabbit.call('CHANGES_REQUESTED')), pull(2, copilot: rabbit.call('APPROVED')))

      sweep.run
      expect(moves.map(&:last)).to eq(%w[do sign_off])
      dispatched = requests.select { |_, path, _| path.end_with?('/dispatches') }
      expect(dispatched.map { |_, _, body| body.dig(:inputs, :number) }).to eq(%w[1])
    end

    it 'treats the maintainer own pull requests as work to finish or merge' do
      pulls.push(pull(1, association: 'OWNER', author: 'crmne'),
                 pull(2, association: 'OWNER', author: 'crmne', copilot: copilot(:changes)),
                 pull(3, association: 'OWNER', author: 'crmne', draft: true))

      sweep.run
      expect(moves.map(&:last)).to eq(%w[sign_off do do])
    end

    it 'leaves a closer look to the agent and sends an unjudged review to triage once' do
      pulls.push(pull(1, copilot: copilot(:closer)),
                 pull(2, status: 'Sign off', copilot: copilot(:closer), next_at: '2026-10-01T09:00:00Z'),
                 pull(3, status: 'Sign off', copilot: copilot(:closer), next_at: '2026-10-01T11:00:00Z'))

      sweep.run
      expect(moves).to eq([%w[new-pr-1 do]])
      dispatched = requests.select { |_, path, _| path.end_with?('/dispatches') }
      expect(dispatched.map { |_, _, body| body.dig(:inputs, :number) }).to eq(%w[1 2])
      expect(dispatched.first).to eq(['POST', 'repos/crmne/spotifast/actions/workflows/issue-assessment.yml/dispatches',
                                      { ref: 'main', inputs: { kind: 'pull_request', number: '1', dry_run: 'false' } }])
    end

    it 'keeps a question the agent put to the maintainer' do
      pulls.push(pull(1, status: 'Decide', copilot: copilot(:approve)))

      sweep.run
      expect(moves).to be_empty
    end

    it 'requests the maintainer review in Sign off and Do and withdraws it elsewhere' do
      pulls.push(pull(1, copilot: copilot(:approve)),
                 pull(2, status: 'Their move', requested: %w[crmne copilot-pull-request-reviewer],
                         copilot: copilot(:changes, commit: 'older')),
                 pull(3, status: 'Do', requested: 'crmne'),
                 pull(4, association: 'OWNER', author: 'crmne'))

      sweep.run
      expect(review_requests).to eq([
                                      { pullRequestId: 'pr-1', userLogins: ['crmne'], union: true },
                                      { pullRequestId: 'pr-2', union: false, userLogins: [],
                                        botLogins: ['copilot-pull-request-reviewer[bot]'], teamSlugs: [] }
                                    ])
    end
  end

  it 'moves finished work to Done, and archives what was already there at the next sweep' do
    old = (Time.now.utc - (8 * 86_400)).iso8601
    recent = (Time.now.utc - 3600).iso8601
    finished['issues'] = [{ 'number' => 1, 'projectItems' => { 'nodes' => card(1, 'Do') } },
                          { 'number' => 2, 'projectItems' => { 'nodes' => [] } },
                          { 'number' => 4, 'projectItems' => { 'nodes' => card(4, 'Done', updated_at: old) } }]
    finished['pullRequests'] = [{ 'number' => 3, 'projectItems' => { 'nodes' => card(3, 'Sign off') } },
                                { 'number' => 5, 'projectItems' => { 'nodes' => card(5, 'Done', updated_at: recent) } }]

    sweep.run
    expect(moves).to eq([%w[item-1 done], %w[item-3 done]])
    expect(archived).to eq(%w[item-4 item-5])
  end

  context 'with archive_after_days' do
    let(:settings) { super().merge('archive_after_days' => 7) }

    it 'keeps finished work in Done that long' do
      finished['issues'] = [{ 'number' => 4, 'projectItems' => {
        'nodes' => card(4, 'Done', updated_at: (Time.now.utc - 86_400).iso8601)
      } }]

      sweep.run
      expect(archived).to be_empty
    end
  end

  it 'archives an open item put in Done by hand, and brings it back only when someone comments' do
    issues.push(issue(1, status: 'Done', updated_at: '2026-10-02T10:00:00Z',
                         comments: [comment('NONE', '2026-10-01T00:00:00Z')]))
    dismissed = issue(2, status: 'Done', updated_at: '2026-10-02T10:00:00Z',
                         comments: [comment('NONE', '2026-10-01T00:00:00Z')])
    dismissed['projectItems']['nodes'].first['isArchived'] = true
    revived = issue(3, status: 'Done', updated_at: '2026-10-02T10:00:00Z',
                       comments: [comment('NONE', '2026-10-03T00:00:00Z')])
    revived['projectItems']['nodes'].first['isArchived'] = true
    issues.push(dismissed, revived)

    sweep.run
    expect(archived).to eq(%w[item-1])
    expect(moves).to eq([%w[new-issue-3 decide]])
  end

  it 'keeps a proposal or a hand placement made after the maintainer last spoke' do
    issues.push(issue(1, status: 'Sign off', updated_at: '2026-10-02T00:00:00Z',
                         comments: [comment('OWNER', '2026-10-01T00:00:00Z', login: 'crmne')]))

    sweep.run
    expect(moves).to be_empty
  end

  it 'writes a next step for the column a card moved to' do
    pulls.push(pull(1, status: 'Do', mergeable: 'CONFLICTING'))

    sweep.run
    expect(steps).to eq([['item-1', 'Conflicts with the base branch: the author rebases']])
  end

  it 'sends a pull request parked in Decide back to its author when it stops being mergeable' do
    pulls.push(pull(1, status: 'Decide', mergeable: 'CONFLICTING'), pull(2, status: 'Decide'))

    sweep.run
    expect(moves).to eq([%w[item-1 theirs]])
  end

  it 'places a proposed closure again once the issue is reopened or the maintainer joins' do
    reopened = issue(1, status: 'Sign off', labels: ['bug'], comments: [comment('NONE')])
    reopened['stateReason'] = 'REOPENED'
    issues.push(reopened,
                issue(2, status: 'Sign off', comments: [comment('NONE', '2026-09-01T00:00:00Z'),
                                                        comment('OWNER', login: 'crmne')]),
                issue(3, status: 'Sign off', comments: [comment('NONE')]))

    sweep.run
    expect(moves).to eq([%w[item-1 do], %w[item-2 theirs]])
  end

  it 'places a reopened card again, bringing it back from the archive' do
    archived_card = issue(2, status: 'Done')
    archived_card['projectItems']['nodes'].first['isArchived'] = true
    issues.push(issue(1, status: 'Done', labels: ['bug']), archived_card)

    sweep.run
    expect(moves).to eq([%w[item-1 do], %w[new-issue-2 decide]])
    expect(board).to have_received(:add).with('issue-2')
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
    expect(sweep).to have_received(:puts).with('#1: new card to Decide')
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
