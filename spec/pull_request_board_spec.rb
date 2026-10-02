# frozen_string_literal: true

require_relative '../lib/assessment'

RSpec.describe IssueAssessment, 'with a pull request on the board' do
  let(:environment) do
    { 'GITHUB_REPOSITORY' => 'crmne/ruby_llm', 'TRIAGE_NUMBER' => '77', 'TRIAGE_KIND' => 'pull_request',
      'TRIAGE_CONFIG' => 'pr-board.yml', 'COPILOT_GITHUB_TOKEN' => 'copilot-token', 'TRIAGE_STATE_DIR' => 'state',
      'TRIAGE_PROJECT_TOKEN' => 'project-token', 'TRIAGE_DEBOUNCE_SECONDS' => '0' }
  end
  let(:copilot_review) do
    { 'author' => { 'login' => 'copilot-pull-request-reviewer' }, 'state' => 'COMMENTED',
      'submittedAt' => '2026-10-01T10:00:00Z', 'commit' => { 'oid' => 'a' * 40 },
      'body' => "## Copilot review overview\n\n### 🔵 Needs a closer look\n\nBroad change; a human should look." }
  end
  let(:item) do
    { 'id' => 'pr-id', 'title' => 'Add streaming retries', 'body' => 'Retries dropped streams.', 'closed' => false,
      'author' => { 'login' => 'contributor' }, 'authorAssociation' => 'CONTRIBUTOR', 'isDraft' => false,
      'headRefOid' => 'a' * 40, 'changedFiles' => 1, 'additions' => 40, 'deletions' => 3,
      'files' => { 'nodes' => [{ 'path' => 'lib/stream.rb', 'additions' => 40, 'deletions' => 3,
                                 'changeType' => 'MODIFIED' }] },
      'reviews' => { 'nodes' => [copilot_review] }, 'reviewRequests' => { 'nodes' => [] },
      'assignees' => { 'totalCount' => 0 }, 'comments' => { 'nodes' => [] } }
  end
  let(:labels) { [{ 'id' => 'enhancement-id', 'name' => 'enhancement' }] }
  let(:decision) do
    { labels: ['enhancement'], reply: nil, comment: nil, sources: [], related_issue: nil, relationship: nil,
      mute: false, review: false, out_of_scope: false, next_move: 'sign_off', priority: 'normal',
      next_step: 'Merge it; Copilot only flagged the breadth of the change' }
  end
  let(:board) { instance_double(ProjectBoard, update: {}) }

  def run_with(event_name: 'workflow_dispatch', action: nil)
    if action
      File.write('event.json', JSON.generate(
                                 'action' => action, 'repository' => { 'full_name' => 'crmne/ruby_llm' },
                                 'review' => { 'user' => { 'login' => 'copilot-pull-request-reviewer[bot]' } },
                                 'pull_request' => { 'number' => 77,
                                                     'head' => { 'repo' => { 'full_name' => 'crmne/ruby_llm' } } }
                               ))
      environment.merge!('GITHUB_EVENT_NAME' => event_name, 'GITHUB_EVENT_PATH' => 'event.json')
    end
    runner = described_class.new(environment)
    allow(runner).to receive_messages(read_report: [item, labels], board: board)
    allow(runner).to receive(:ask_copilot) { JSON.generate(decision) }
    allow(runner).to receive(:mutate)
    allow(runner).to receive(:github)
    allow(runner).to receive(:puts)
    runner.run
    runner
  end

  before do
    allow(board).to receive(:column_name) { |key| ProjectBoard::COLUMNS.fetch(key) }
    config = YAML.safe_load_file('triage.yml').merge('pull_requests' => {},
                                                     'board' => { 'project' => 'https://github.com/users/crmne/projects/1',
                                                                  'maintainer' => 'crmne' })
    File.write('pr-board.yml', YAML.dump(config))
  end

  it "shows the agent Copilot's verdict on the latest commit" do
    runner = run_with

    expect(runner).to have_received(:ask_copilot).with(include('"copilot_review":', '"verdict":"closer_look"',
                                                               '"current":true', 'Broad change'))
  end

  it 'puts an approvable pull request in Sign off and requests the maintainer review' do
    runner = run_with

    expect(board).to have_received(:update).with('pr-id', hash_including(column: 'sign_off'))
    expect(runner).to have_received(:github).with(
      'graphql', query: include('requestReviewsByLogin'),
                 variables: { input: { pullRequestId: 'pr-id', userLogins: ['crmne'], union: true } }
    )
  end

  it 'sends a pull request with real problems back to its author and withdraws the review request' do
    decision[:next_move] = 'theirs'
    item['reviewRequests']['nodes'] << { 'requestedReviewer' => { '__typename' => 'User', 'login' => 'crmne' } }
    runner = run_with

    expect(board).to have_received(:update).with('pr-id', hash_including(column: 'theirs'))
    expect(runner).to have_received(:github).with(
      'graphql', query: include('requestReviewsByLogin'),
                 variables: { input: { pullRequestId: 'pr-id', union: false, userLogins: [], botLogins: [],
                                       teamSlugs: [] } }
    )
  end

  it "places the maintainer's own pull request without the model or a review request" do
    item.merge!('author' => { 'login' => 'crmne' }, 'authorAssociation' => 'OWNER', 'mergeable' => 'MERGEABLE')
    runner = run_with

    expect(runner).not_to have_received(:ask_copilot)
    expect(board).to have_received(:update).with('pr-id', column: 'sign_off',
                                                          movable: ProjectBoard::MOVABLE - ['decide'])
    expect(runner).not_to have_received(:github).with('graphql',
                                                      hash_including(query: include('requestReviewsByLogin')))
  end

  it "keeps the maintainer's own pull request out of Sign off when its checks cannot be read" do
    item.merge!('author' => { 'login' => 'crmne' }, 'authorAssociation' => 'OWNER', 'mergeable' => 'MERGEABLE')
    runner = described_class.new(environment)
    allow(runner).to receive_messages(read_report: [item, labels], board: board)
    allow(runner).to receive(:ask_copilot)
    allow(runner).to receive(:puts)
    allow(runner).to receive(:github).and_raise(RuntimeError, 'GitHub request failed')
    runner.run

    expect(runner).not_to have_received(:ask_copilot)
    expect(board).to have_received(:update).with('pr-id', column: 'do', movable: ProjectBoard::MOVABLE - ['decide'])
  end

  it "assesses Copilot's review as a new update" do
    run_with
    item['reviews']['nodes'] << copilot_review.merge('body' => "### 🟢 Approval recommended\n\nNarrow and tested.")
    runner = run_with(event_name: 'pull_request_review', action: 'submitted')

    expect(runner).to have_received(:ask_copilot).with(include('Copilot review update', 'Approval recommended'))
  end

  it 'parks the pull request in Their move after a push, until Copilot reviews it' do
    decision[:review] = true
    run_with
    item['headRefOid'] = 'b' * 40
    pushed = run_with(event_name: 'pull_request_target', action: 'synchronize')

    expect(pushed).not_to have_received(:ask_copilot)
    expect(board).to have_received(:update).with('pr-id', column: 'theirs')
  end
end
