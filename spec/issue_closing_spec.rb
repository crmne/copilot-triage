# frozen_string_literal: true

require_relative '../lib/assessment'

RSpec.describe IssueAssessment, 'closing issues' do
  let(:environment) do
    { 'GITHUB_REPOSITORY' => 'crmne/ruby_llm', 'TRIAGE_NUMBER' => '123', 'TRIAGE_KIND' => 'issue',
      'COPILOT_GITHUB_TOKEN' => 'test-copilot-token', 'TRIAGE_CONFIG' => 'closing-triage.yml',
      'TRIAGE_PROJECT_TOKEN' => 'project-token' }
  end
  let(:closing) { 'auto' }
  let(:assessment) { described_class.new(environment) }
  let(:reporter_comment) do
    { 'id' => 'c1', 'createdAt' => '2026-10-01T10:00:00Z', 'body' => 'Works on 1.9.1, thanks!',
      'author' => { 'login' => 'reporter' }, 'authorAssociation' => 'NONE' }
  end
  let(:item) do
    { 'id' => 'report-id', 'title' => 'Streaming broke in 1.9', 'body' => 'Every stream now raises.',
      'closed' => false, 'author' => { 'login' => 'reporter' }, 'authorAssociation' => 'NONE',
      'assignees' => { 'totalCount' => 0 }, 'comments' => { 'nodes' => [reporter_comment] } }
  end
  let(:labels) { [{ 'id' => 'bug-id', 'name' => 'bug' }] }
  let(:decision) do
    { labels: [], reply: nil, comment: 'Glad it works now; closing.', sources: [], close_as: 'resolved',
      next_move: 'theirs', priority: 'normal', next_step: 'Nothing; the reporter confirmed the fix.' }
  end
  let(:board) { instance_double(ProjectBoard, update: {}) }

  before do
    config = YAML.safe_load_file('triage.yml').merge('closing' => closing, 'followups' => 'all')
    config['board'] = { 'project' => 'https://github.com/users/crmne/projects/3' }
    File.write('closing-triage.yml', YAML.dump(config))
    allow(assessment).to receive_messages(read_report: [item, labels], board: board)
    allow(assessment).to receive(:ask_copilot) { JSON.generate(decision) }
    allow(assessment).to receive(:mutate)
    allow(assessment).to receive(:github)
    allow(assessment).to receive(:puts)
  end

  it 'closes an issue the reporter says is resolved, after explaining, and moves its card to Done' do
    assessment.run

    expect(assessment).to have_received(:mutate).with('addComment', hash_including(subjectId: 'report-id')).ordered
    expect(assessment).to have_received(:mutate)
      .with('closeIssue', issueId: 'report-id', stateReason: 'COMPLETED').ordered
    expect(board).to have_received(:update)
      .with('report-id', hash_including(column: 'done', movable: [nil, *ProjectBoard::COLUMNS.keys]))
    expect(assessment).to have_received(:puts).with(include('"outcome":"closed_as_resolved"'))
  end

  it 'closes out-of-scope requests as not planned' do
    decision.merge!(close_as: 'out_of_scope', sources: ['file:docs/tools.md'],
                    comment: 'Tools are out of scope, see [[file:docs/tools.md]].')
    allow(assessment).to receive(:ask_copilot) do
      agent_reads(assessment, 'file:docs/tools.md')
      JSON.generate(decision)
    end
    assessment.run

    expect(assessment).to have_received(:mutate).with('closeIssue', issueId: 'report-id', stateReason: 'NOT_PLANNED')
  end

  it 'only proposes a resolution the reporter did not state' do
    item['comments']['nodes'] = [reporter_comment.merge('author' => { 'login' => 'someone-else' })]
    assessment.run

    expect(assessment).not_to have_received(:mutate).with('closeIssue', anything)
    expect(board).to have_received(:update).with('report-id', hash_including(column: 'sign_off'))
  end

  it 'leaves closing to the maintainer once they joined the conversation' do
    item['comments']['nodes'].unshift(reporter_comment.merge('id' => 'c0', 'authorAssociation' => 'OWNER',
                                                             'author' => { 'login' => 'crmne' }))
    assessment.run

    expect(assessment).not_to have_received(:mutate).with('closeIssue', anything)
    expect(board).to have_received(:update).with('report-id', hash_including(column: 'sign_off'))
  end

  it 'never closes a reopened issue or one a maintainer opened' do
    item['stateReason'] = 'REOPENED'
    assessment.run
    expect(assessment).not_to have_received(:mutate).with('closeIssue', anything)

    item.delete('stateReason')
    item['authorAssociation'] = 'OWNER'
    described_class.new(environment).tap do |again|
      allow(again).to receive_messages(read_report: [item, labels], board: board, ask_copilot: JSON.generate(decision))
      allow(again).to receive(:mutate)
      allow(again).to receive(:github)
      allow(again).to receive(:puts)
      again.run
      expect(again).not_to have_received(:mutate).with('closeIssue', anything)
    end
  end

  context 'when the policy only suggests closing' do
    let(:closing) { 'suggest' }

    it 'proposes the closure in Sign off' do
      assessment.run

      expect(assessment).not_to have_received(:mutate).with('closeIssue', anything)
      expect(board).to have_received(:update).with('report-id', hash_including(column: 'sign_off'))
      expect(assessment).to have_received(:ask_copilot).with(include('Closing is proposed to the maintainer'))
    end
  end
end
