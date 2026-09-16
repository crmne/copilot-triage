# frozen_string_literal: true

require_relative '../lib/assessment'

RSpec.describe 'Copilot structured output' do
  let(:assessment) do
    IssueAssessment.new('GITHUB_REPOSITORY' => 'owner/project', 'TRIAGE_NUMBER' => '1',
                        'TRIAGE_CONFIG' => 'triage.yml')
  end
  let(:decision) { JSON.generate(labels: [], reply: nil, sources: []) }
  let(:events) do
    [{ type: 'assistant.message', data: { content: 'I will check the evidence.' } },
     { type: 'assistant.message_delta', data: { deltaContent: '{' } },
     { type: 'assistant.message', data: { content: decision } },
     { type: 'result', exitCode: 0 }]
  end

  def response
    assessment.send(:copilot_response, events.map { |event| JSON.generate(event) }.join("\n"))
  end

  it 'uses the final complete assistant message without concatenating commentary or streaming deltas' do
    expect(response).to eq(decision)
  end

  it 'does not recover an earlier decision when the final answer is not JSON' do
    events.insert(-2, { type: 'assistant.message', data: { content: 'Not a decision.' } })
    expect(response).to eq('Not a decision.')
  end

  it 'requires successful session completion' do
    events.last[:exitCode] = 1
    expect(response).to be_nil
  end

  it 'rejects interrupted streams without a result' do
    events.pop
    expect(response).to be_nil
  end

  it 'ignores non-assistant content' do
    events.replace([{ type: 'user.message', data: { content: decision } }, { type: 'result', exitCode: 0 }])
    expect(response).to be_nil
  end

  it 'limits preview diagnostics to final text and tool decisions, with tokens redacted' do
    assessment.instance_variable_get(:@environment)['GH_TOKEN'] = 'private-token'
    events.insert(-2, { type: 'assistant.reasoning', data: { content: 'Hidden reasoning.' } })
    events.insert(-2, { type: 'assistant.message', data: { content: 'private-token' } })
    allow(assessment).to receive(:puts)

    assessment.send(:debug_copilot, events.map { |event| JSON.generate(event) }.join("\n"))

    expect(assessment).to have_received(:puts).with(include('[REDACTED]'))
    expect(assessment).not_to have_received(:puts).with(include('private-token'))
    expect(assessment).not_to have_received(:puts).with(include('Hidden reasoning.'))
  end
end
