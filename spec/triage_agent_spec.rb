# frozen_string_literal: true

require_relative '../lib/triage_agent'

RSpec.describe TriageAgent do
  let(:config) { YAML.safe_load_file('triage.yml') }
  let(:toolbox) { TriageTools.new(root: Dir.pwd, repository: 'owner/project', config: config) }
  let(:context) { RubyLLM.context { |settings| settings.openai_api_key = 'test-key' } }
  let(:agent) do
    described_class.new(toolbox:, system_prompt: 'Triage it.', model: 'triage-test-model', provider: :openai,
                        assume_model_exists: true, context:)
  end
  let(:silence) do
    { 'labels' => [], 'reply' => nil, 'comment' => nil, 'sources' => [], 'related_issue' => nil,
      'relationship' => nil, 'mute' => false }
  end

  it 'gives the model the same tools, descriptions, and schemas as the Copilot agent' do
    tools = agent.tools.values

    expect(tools.map(&:name)).to eq(toolbox.definitions.map { |tool| tool[:name] })
    expect(tools.map { |tool| [tool.description, tool.parameters_schema] })
      .to eq(toolbox.definitions.map { |tool| tool.values_at(:description, :inputSchema) })
    expect(agent.messages.first.content).to eq('Triage it.')
  end

  it 'includes the board fields when the toolbox has them' do
    toolbox = TriageTools.new(root: Dir.pwd, repository: 'owner/project', config: config, board: true)
    agent = described_class.new(toolbox:, system_prompt: 'Triage it.', model: 'triage-test-model',
                                provider: :openai, assume_model_exists: true, context:)

    submit = agent.tools.values.find { |tool| tool.name == 'submit_decision' }
    expect(submit.parameters_schema[:required]).to include('next_move', 'priority', 'next_step')
  end

  it 'runs tools through the toolbox and returns its errors as text the model can correct' do
    search = agent.tools.values.find { |tool| tool.name == 'search_repository' }
    submit = agent.tools.values.find { |tool| tool.name == 'submit_decision' }

    expect(JSON.parse(search.call(query: ''))['results']).not_to be_empty
    expect(submit.call(**silence, 'labels' => ['approved'])).to eq('Choose only configured labels.')
    expect(toolbox.ledger['calls']).to eq(1)
  end

  it 'stops as soon as the decision is submitted' do
    allow(agent).to receive(:step) { toolbox.call('submit_decision', silence) }

    agent.triage('Report')
    expect(agent).to have_received(:step).once
    expect(toolbox.ledger['decision']).to eq(silence)
  end

  it 'gives up after the turn budget' do
    allow(agent).to receive_messages(complete?: false, turns: described_class::MAX_TURNS)
    allow(agent).to receive(:step)

    expect { agent.triage('Report') }.to raise_error(described_class::Exhausted, /20 model turns/)
    expect(agent).not_to have_received(:step)
  end
end
