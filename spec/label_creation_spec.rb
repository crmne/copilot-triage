# frozen_string_literal: true

require_relative '../lib/assessment'

RSpec.describe IssueAssessment, 'creating missing labels', :label_creation do
  let(:environment) do
    { 'GITHUB_REPOSITORY' => 'crmne/ruby_llm', 'TRIAGE_NUMBER' => '123', 'TRIAGE_KIND' => 'issue',
      'COPILOT_GITHUB_TOKEN' => 'copilot-token', 'TRIAGE_CONFIG' => 'triage.yml' }
  end
  let(:assessment) { described_class.new(environment) }
  let(:item) do
    { 'id' => 'report-id', 'title' => 'Crash', 'body' => 'It crashes.', 'closed' => false,
      'author' => { 'login' => 'reporter' }, 'comments' => { 'nodes' => [] } }
  end
  let(:existing) { [{ 'id' => 'bug-id', 'name' => 'bug' }] }

  before do
    allow(assessment).to receive_messages(read_report: [item, existing],
                                          ask_copilot: JSON.generate(labels: ['question'], reply: nil, sources: []))
    allow(assessment).to receive(:mutate)
    allow(assessment).to receive(:puts)
    allow(assessment).to receive(:github) do |_path, name:, **|
      { 'node_id' => "#{name}-id", 'name' => name }
    end
  end

  it 'creates the policy labels a repository lacks, then uses them' do
    assessment.run

    created = YAML.safe_load_file('triage.yml').fetch('labels').keys - ['bug']
    created.each do |name|
      expect(assessment).to have_received(:github).with('repos/crmne/ruby_llm/labels', hash_including(name: name))
    end
    expect(assessment).to have_received(:github).with(anything, hash_including(name: 'question', color: 'd876e3'))
    expect(assessment).to have_received(:mutate).with('addLabelsToLabelable', labelableId: 'report-id',
                                                                              labelIds: ['question-id'])
  end

  it 'creates nothing in a dry run' do
    environment['TRIAGE_DRY_RUN'] = 'true'
    assessment.run

    expect(assessment).not_to have_received(:github)
  end
end
