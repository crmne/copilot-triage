# frozen_string_literal: true

require_relative '../lib/assessment'
require_relative '../lib/triage_agent'

RSpec.describe IssueAssessment, 'with the RubyLLM engine' do
  let(:environment) do
    { 'GITHUB_REPOSITORY' => 'crmne/ruby_llm', 'TRIAGE_NUMBER' => '123', 'TRIAGE_KIND' => 'issue',
      'TRIAGE_CONFIG' => 'triage.yml', 'TRIAGE_ENGINE' => 'rubyllm', 'TRIAGE_PROVIDER' => 'openrouter',
      'TRIAGE_MODEL' => 'openai/gpt-oss-120b', 'TRIAGE_API_KEY' => 'sk-or-secret' }
  end
  let(:assessment) { described_class.new(environment) }
  let(:item) do
    { 'id' => 'report-id', 'title' => 'Tool call raises an error', 'body' => 'Here is a complete reproduction.',
      'closed' => false, 'author' => { 'login' => 'reporter' }, 'comments' => { 'nodes' => [] } }
  end
  let(:labels) { [{ 'id' => 'bug-id', 'name' => 'bug' }] }
  let(:decision) do
    { 'labels' => ['bug'], 'reply' => nil, 'comment' => nil, 'sources' => [], 'related_issue' => nil,
      'relationship' => nil, 'mute' => false }
  end
  let(:agent) do
    instance_double(TriageAgent, turns: 3, tokens: RubyLLM::Tokens.new(input: 9000, output: 120),
                                 cost: instance_double(RubyLLM::Cost, total: 0.0021))
  end
  let(:built) { {} }

  before do
    allow(assessment).to receive_messages(read_report: [item, labels])
    allow(assessment).to receive(:mutate)
    allow(assessment).to receive(:puts)
    allow(TriageAgent).to receive(:new) do |toolbox:, **options|
      built.merge!(options)
      allow(agent).to receive(:triage) { toolbox.call('submit_decision', decision) }
      agent
    end
  end

  it 'triages with the configured provider and model and records usage and cost' do
    assessment.run

    expect(built).to include(model: 'openai/gpt-oss-120b', provider: :openrouter, assume_model_exists: false)
    expect(built.fetch(:context).config.openrouter_api_key).to eq('sk-or-secret')
    expect(built.fetch(:system_prompt)).to include('Project policy:')
    expect(assessment).to have_received(:mutate).with('addLabelsToLabelable', labelableId: 'report-id',
                                                                              labelIds: ['bug-id'])
    expect(assessment).to have_received(:puts).with(include('"model_calls":3', '"input_tokens":9000',
                                                            '"cost_usd":0.0021', '"engine":"rubyllm"'))
  end

  it 'accepts models a custom endpoint serves without a registry entry' do
    environment.merge!('TRIAGE_PROVIDER' => 'ollama', 'TRIAGE_API_BASE' => 'http://localhost:11434/v1',
                       'TRIAGE_API_KEY' => '')

    assessment.run
    expect(built).to include(provider: :ollama, assume_model_exists: true)
    expect(built.fetch(:context).config.ollama_api_base).to eq('http://localhost:11434/v1')
  end

  it 'shows the cost in the reply footer' do
    decision.merge!('labels' => [], 'reply' => 'version')

    assessment.run
    expect(assessment).to have_received(:mutate)
      .with('addComment', subjectId: 'report-id', body: include('9000 input / 120 output tokens ($0.0021) this run'))
  end

  it 'leaves the report unchanged and redacts the key when the provider fails' do
    allow(TriageAgent).to receive(:new).and_return(agent)
    allow(agent).to receive(:triage).and_raise(RubyLLM::UnauthorizedError.new('bad key sk-or-secret'))

    assessment.run
    expect(assessment).to be_failed
    expect(assessment).not_to have_received(:mutate)
    expect(assessment).to have_received(:puts).with('Failed: model unavailable (bad key [REDACTED]); ' \
                                                    'left for a maintainer.')
  end

  it 'fails clearly without a provider or with an unknown one' do
    environment.delete('TRIAGE_PROVIDER')
    assessment.run
    expect(assessment).to have_received(:puts).with(start_with('Failed: the rubyllm engine needs a provider'))

    other = described_class.new(environment.merge('TRIAGE_PROVIDER' => 'nowhere'))
    allow(other).to receive_messages(read_report: [item, labels], puts: nil)
    other.run
    expect(other).to have_received(:puts).with(start_with('Failed: RubyLLM has no nowhere provider'))
  end

  it 'rejects an unknown engine' do
    expect { described_class.new(environment.merge('TRIAGE_ENGINE' => 'gpt')) }
      .to raise_error(ArgumentError, 'engine must be copilot or rubyllm')
  end
end
