# frozen_string_literal: true

require_relative '../lib/assessment'

RSpec.describe 'Agent-selected related issues and guarded publishing' do
  let(:environment) do
    { 'GITHUB_REPOSITORY' => 'owner/project', 'TRIAGE_NUMBER' => '123',
      'TRIAGE_KIND' => 'issue', 'TRIAGE_CONFIG' => 'triage.yml' }
  end
  let(:assessment) { IssueAssessment.new(environment) }
  let(:mode) { 'close' }
  let(:item) do
    { 'id' => 'current-id', 'title' => 'Remember the theme', 'body' => 'The theme resets after restarting.',
      'closed' => false, 'stateReason' => nil, 'authorAssociation' => 'NONE',
      'author' => { 'login' => 'reporter' }, 'comments' => { 'nodes' => [] } }
  end
  let(:candidate) do
    { 'node_id' => 'candidate-id', 'number' => 42, 'title' => 'Persist theme across restarts',
      'body' => 'The selected theme resets each time I restart.', 'state' => 'open', 'comments' => 0,
      'html_url' => 'https://github.com/owner/project/issues/42' }
  end
  let(:decision) do
    { labels: [], reply: nil, sources: [], related_issue: 42, relationship: 'duplicate',
      comment: 'Both reports describe the selected theme resetting after a restart.' }
  end

  before do
    config = YAML.safe_load_file('triage.yml').merge('duplicates' => mode)
    File.write('triage.yml', YAML.dump(config))
    allow(assessment).to receive_messages(read_report: [item, []], puts: nil, mutate: nil)
    allow(assessment.send(:evidence_tools)).to receive(:api) { Marshal.load(Marshal.dump(candidate)) }
    allow(assessment).to receive(:ask_copilot) do
      agent_reads(assessment, 'issue:42')
      JSON.generate(decision)
    end
  end

  it 'uses the agent decision without a second comparison prompt' do
    expect(assessment).to receive(:mutate).with('addComment',
                                                hash_including(body: start_with('Duplicate of #42.'))).ordered
    expect(assessment).to receive(:mutate).with(
      'closeIssue', issueId: 'current-id', stateReason: 'DUPLICATE', duplicateIssueId: 'candidate-id'
    ).ordered
    expect(assessment).to receive(:mutate).with('addReaction', anything).ordered
    assessment.run
    expect(assessment).to have_received(:ask_copilot).once
  end

  it 'suggests without closing when configured' do
    assessment.instance_variable_get(:@config)['duplicates'] = 'suggest'
    assessment.run
    expect(assessment).to have_received(:mutate).with('addComment', hash_including(body: start_with('See also #42.')))
    expect(assessment).not_to have_received(:mutate).with('closeIssue', anything)
  end

  it 'leaves a related but distinct report open' do
    decision[:relationship] = 'related'
    assessment.run
    expect(assessment).to have_received(:mutate).with('addComment', anything)
    expect(assessment).not_to have_received(:mutate).with('closeIssue', anything)
  end

  it 'closes duplicate discussions through the discussion API' do
    assessment.instance_variable_set(:@kind, 'discussion')
    assessment.run
    expect(assessment).to have_received(:mutate).with('closeDiscussion', discussionId: 'current-id',
                                                                         reason: 'DUPLICATE')
  end

  {
    'older issue' => ->(runner, _item) { runner.instance_variable_set(:@number, 12) },
    'reopened issue' => ->(_runner, report) { report['stateReason'] = 'REOPENED' },
    'maintainer-authored issue' => ->(_runner, report) { report['authorAssociation'] = 'OWNER' },
    'maintainer participation' => lambda { |_runner, report|
      report['comments']['nodes'] = [{ 'body' => 'Keep open.', 'authorAssociation' => 'COLLABORATOR' },
                                     { 'body' => 'More details.', 'authorAssociation' => 'NONE' }]
    }
  }.each do |name, change|
    it "does not auto-close an #{name}" do
      change.call(assessment, item)
      assessment.run
      expect(assessment).to have_received(:mutate).with('addComment', anything)
      expect(assessment).not_to have_received(:mutate).with('closeIssue', anything)
    end
  end

  it 'requires reading the candidate, not just searching titles' do
    allow(assessment).to receive(:ask_copilot).and_return(JSON.generate(decision))
    assessment.run
    expect(assessment).not_to have_received(:mutate)
  end

  it 'requires the complete candidate, not a truncated preview' do
    candidate['body'] = 'Important distinct requirements. ' * 1000
    allow(assessment).to receive(:ask_copilot) do
      tools = assessment.send(:evidence_tools)
      tools.call('read_evidence', { 'reference' => 'issue:42' })
      assessment.instance_variable_set(:@tool_ledger, tools.ledger)
      JSON.generate(decision)
    end
    assessment.run
    expect(assessment).not_to have_received(:mutate)
  end

  it 'rejects closing against itself, a closed candidate, or disabled duplicate policy' do
    candidate['state'] = 'closed'
    assessment.run
    expect(assessment).not_to have_received(:mutate)
  end

  it 'rechecks remote evidence after inference' do
    allow(assessment).to receive(:ask_copilot) do
      agent_reads(assessment, 'issue:42')
      candidate['state'] = 'closed'
      JSON.generate(decision)
    end
    assessment.run
    expect(assessment).not_to have_received(:mutate)
  end

  it 'rechecks the current report before publishing' do
    allow(assessment).to receive(:read_report).and_return([item, []], [item.merge('body' => 'Changed.'), []])
    assessment.run
    expect(assessment).not_to have_received(:mutate)
  end

  it 'does not complete a run when closing fails' do
    allow(assessment).to receive(:mutate).with('closeIssue', anything).and_raise('GitHub failed')
    expect { assessment.run }.to raise_error('GitHub failed')
    expect(assessment).not_to have_received(:mutate).with('addReaction', anything)
  end

  it 'previews closure without mutations' do
    environment['TRIAGE_DRY_RUN'] = 'true'
    assessment.run
    expect(assessment).not_to have_received(:mutate)
    expect(assessment).to have_received(:puts).with(include('"close":true'))
  end
end
