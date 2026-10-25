# frozen_string_literal: true

require_relative '../lib/assessment'

RSpec.describe IssueAssessment, 'with a fallback model' do
  let(:environment) do
    { 'GITHUB_REPOSITORY' => 'crmne/ruby_llm', 'TRIAGE_NUMBER' => '123', 'TRIAGE_CONFIG' => 'triage.yml',
      'COPILOT_GITHUB_TOKEN' => 'copilot-token', 'TRIAGE_FALLBACK_API_KEY' => 'sk-or-fallback' }
  end
  let(:assessment) { described_class.new(environment) }
  let(:quota) { { 'remaining' => 12, 'unlimited' => false, 'overage_permitted' => false } }

  before do
    allow(Open3).to receive(:capture3).and_call_original
    allow(Open3).to receive(:capture3).with(hash_including('GH_TOKEN' => 'copilot-token'), 'gh', 'api',
                                            'copilot_internal/user') do
      [JSON.generate('quota_snapshots' => { 'premium_interactions' => quota }), '',
       instance_double(Process::Status, success?: true)]
    end
    allow(assessment).to receive_messages(ask_copilot: '{"copilot": true}', ask_rubyllm: '{"fallback": true}')
    allow(assessment).to receive(:puts)
  end

  it 'triages with the fallback model once the Copilot allowance is spent' do
    expect(assessment.send(:ask_model, 'prompt')).to eq('{"fallback": true}')
    expect(assessment).not_to have_received(:ask_copilot)
    environment = assessment.instance_variable_get(:@environment)
    expect(environment).to include('TRIAGE_PROVIDER' => 'openrouter', 'TRIAGE_MODEL' => 'openai/gpt-5.6-luna',
                                   'TRIAGE_API_KEY' => 'sk-or-fallback')
    expect(assessment.send(:redact, 'key sk-or-fallback')).to eq('key [REDACTED]')
  end

  it 'runs the fallback once more when it finishes without a decision, as on ZapFast #550' do
    attempts = 0
    allow(assessment).to receive(:ask_rubyllm) do
      attempts += 1
      next '{"fallback": true}' if attempts == 2

      assessment.instance_variable_set(:@model_failure_reason, described_class::NO_DECISION)
      nil
    end

    expect(assessment.send(:request, 'prompt') { |response| response }).to eq('{"fallback": true}')
    expect(assessment).to have_received(:ask_rubyllm).twice
    expect(assessment).not_to have_received(:ask_copilot)
    expect(assessment.instance_variable_get(:@model_calls)).to eq(2)
  end

  it 'does not run again when the model failed for another reason' do
    allow(assessment).to receive(:ask_rubyllm) do
      assessment.instance_variable_set(:@model_failure_reason, 'model unavailable (rate limited)')
      nil
    end

    expect { assessment.send(:request, 'prompt') { |response| response } }
      .to raise_error(described_class::Failed, 'model unavailable (rate limited)')
    expect(assessment).to have_received(:ask_rubyllm).once
  end

  it 'posts from a fallback run like a Copilot run' do
    assessment.send(:ask_model, 'prompt')
    expect(assessment.send(:quiet?)).to be_falsey
  end

  it 'requests no Copilot review once the allowance is spent' do
    item = { 'id' => 'PR_1', 'headRefOid' => 'abc1234def' }
    allow(assessment).to receive(:mutate)
    assessment.instance_variable_set(:@state, ConversationState.new(nil, 'test'))
    assessment.send(:request_review, item)
    expect(assessment).not_to have_received(:mutate)
    expect(assessment).to have_received(:puts).with(a_string_including('allowance is spent'))
  end

  it 'falls back when the environment is the process ENV, as in the action' do
    saved = environment.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    environment.each { |key, value| ENV[key] = value }
    from_env = described_class.new(ENV)
    allow(from_env).to receive_messages(ask_copilot: nil, ask_rubyllm: '{"fallback": true}')
    allow(from_env).to receive(:puts)

    expect(from_env.send(:ask_model, 'prompt')).to eq('{"fallback": true}')
    expect(from_env.instance_variable_get(:@environment)).to include('TRIAGE_API_KEY' => 'sk-or-fallback')
  ensure
    saved.each { |key, value| ENV[key] = value }
  end

  it 'keeps using Copilot while the allowance lasts or overage is allowed' do
    quota['remaining'] = 900
    expect(assessment.send(:ask_model, 'prompt')).to eq('{"copilot": true}')

    quota.merge!('remaining' => 0, 'overage_permitted' => true)
    expect(described_class.new(environment).tap do |other|
      allow(other).to receive_messages(ask_copilot: '{"copilot": true}', ask_rubyllm: nil)
    end.send(:ask_model, 'prompt')).to eq('{"copilot": true}')
  end

  it 'has no fallback without a fallback key' do
    environment.delete('TRIAGE_FALLBACK_API_KEY')
    expect(assessment.send(:ask_model, 'prompt')).to eq('{"copilot": true}')
    expect(Open3).not_to have_received(:capture3).with(anything, 'gh', 'api', 'copilot_internal/user')
  end
end
