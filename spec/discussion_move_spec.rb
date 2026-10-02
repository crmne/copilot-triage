# frozen_string_literal: true

require_relative '../lib/assessment'

RSpec.describe IssueAssessment, 'moving discussions to issues' do
  let(:environment) do
    { 'GITHUB_REPOSITORY' => 'crmne/spotifast', 'TRIAGE_NUMBER' => '41', 'TRIAGE_KIND' => 'discussion',
      'TRIAGE_CONFIG' => 'move-triage.yml', 'COPILOT_GITHUB_TOKEN' => 'copilot-token',
      'TRIAGE_PROJECT_TOKEN' => 'project-token' }
  end
  let(:policy) { { 'discussions' => { 'move_to_issues' => true } } }
  let(:assessment) { described_class.new(environment) }
  let(:item) do
    { 'id' => 'discussion-id', 'url' => 'https://github.com/crmne/spotifast/discussions/41',
      'repository_id' => 'repo-id', 'title' => 'Crash when the queue is empty',
      'body' => 'Pressing next with an empty queue crashes the app.', 'closed' => false,
      'author' => { 'login' => 'listener' }, 'comments' => { 'nodes' => [] } }
  end
  let(:labels) { [{ 'id' => 'bug-id', 'name' => 'bug' }] }
  let(:decision) do
    { labels: ['bug'], reply: nil, comment: 'Crash reports are easier to track as issues.', sources: [],
      related_issue: nil, relationship: nil, mute: false, move_to_issue: true }
  end

  before do
    File.write('move-triage.yml', YAML.dump(YAML.safe_load_file('triage.yml').merge(policy)))
    allow(assessment).to receive_messages(read_report: [item, labels])
    allow(assessment).to receive(:ask_copilot) { JSON.generate(decision) }
    allow(assessment).to receive(:mutate)
    allow(assessment).to receive(:puts)
    allow(assessment).to receive(:github)
      .and_return('data' => { 'createIssue' => { 'issue' => { 'id' => 'issue-id', 'number' => 42 } } })
  end

  it 'creates a labeled issue crediting the author, links it, and closes the discussion' do
    assessment.run

    issue = { repositoryId: 'repo-id', title: 'Crash when the queue is empty', labelIds: ['bug-id'],
              body: "_Moved from https://github.com/crmne/spotifast/discussions/41, opened by @listener._\n\n" \
                    'Pressing next with an empty queue crashes the app.' }
    expect(assessment).to have_received(:github)
      .with('graphql', query: include('createIssue'), variables: { input: issue }).ordered
    expect(assessment).to have_received(:mutate).with(
      'addDiscussionComment', discussionId: 'discussion-id',
                              body: start_with('Moved to #42. Crash reports are easier to track as issues.')
    ).ordered
    expect(assessment).to have_received(:mutate).with('closeDiscussion', discussionId: 'discussion-id',
                                                                         reason: 'OUTDATED').ordered
    expect(assessment).to have_received(:puts).with(include('"outcome":"moved_to_issue"'))
  end

  it 'leaves a question in discussions without labels' do
    decision.merge!(labels: [], comment: nil, move_to_issue: false)
    assessment.run

    expect(assessment).not_to have_received(:github)
    expect(assessment).not_to have_received(:mutate).with('closeDiscussion', anything)
  end

  it 'still rejects labels on a discussion that stays' do
    decision[:move_to_issue] = false
    assessment.run

    expect(assessment).to be_failed
    expect(assessment).not_to have_received(:mutate)
  end

  it 'offers the move only for a new discussion, with the labels and guidance it needs' do
    assessment.instance_variable_set(:@state, ConversationState.new(nil, 'scope'))

    expect(assessment.send(:build_prompt, item, labels)).to include('also submit move_to_issue', '"bug"')
    expect(assessment.send(:system_prompt)).to include('## Discussions that belong in issues')
    expect(assessment.send(:tools_settings, Dir.pwd)).to include(move: true)
  end

  context 'with a board' do
    let(:policy) do
      { 'discussions' => { 'move_to_issues' => true },
        'board' => { 'project' => 'https://github.com/users/crmne/projects/3' } }
    end

    it 'puts the new issue on it' do
      board = instance_double(ProjectBoard, update: {})
      allow(assessment).to receive(:board).and_return(board)
      decision.merge!(next_move: 'do', priority: 'high', next_step: 'Reproduce the empty-queue crash.')

      assessment.run
      expect(board).to have_received(:update).with('issue-id', hash_including(column: 'do'))
    end
  end

  context 'without a discussions policy' do
    let(:policy) { {} }

    it 'moves real issues by default' do
      assessment.run

      expect(assessment).to have_received(:mutate).with('closeDiscussion', discussionId: 'discussion-id',
                                                                           reason: 'OUTDATED')
    end
  end

  context 'when the policy turns moving off' do
    let(:policy) { { 'discussions' => { 'move_to_issues' => false } } }

    it 'keeps discussions as they are' do
      decision.merge!(labels: [], comment: nil).delete(:move_to_issue)
      assessment.run

      expect(assessment).not_to have_received(:github)
      expect(assessment).not_to be_failed
    end
  end
end
