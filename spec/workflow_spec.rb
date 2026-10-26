# frozen_string_literal: true

require 'yaml'
require_relative '../lib/bot_reviews'

RSpec.describe 'the shared triage workflow' do
  it 'saves conversation state on the low-trust events it runs on' do
    workflow = YAML.load_file(File.expand_path('../.github/workflows/assess.yml', __dir__))

    expect(workflow.dig('jobs', 'assess', 'cache-mode')).to eq('write')
  end

  it 'passes quiet through, so a manual backlog run posts nothing' do
    workflow = YAML.load_file(File.expand_path('../.github/workflows/assess.yml', __dir__))

    expect(workflow.dig(true, 'workflow_call', 'inputs', 'quiet')).to eq('type' => 'boolean', 'default' => false)
    expect(workflow.dig('jobs', 'assess', 'steps', 0, 'with', 'quiet')).to eq('${{ inputs.quiet }}')
  end

  it 'gives the sweep the token that asks Copilot to review new pushes' do
    workflow = YAML.load_file(File.expand_path('../.github/workflows/sweep.yml', __dir__))

    expect(workflow.dig('jobs', 'sweep', 'steps', 0, 'with', 'copilot-token'))
      .to eq('${{ secrets.COPILOT_GITHUB_TOKEN }}')
  end

  it 'starts no job for a push where the reviews input rules Copilot out' do
    workflow = YAML.load_file(File.expand_path('../.github/workflows/assess.yml', __dir__))
    condition = workflow.dig('jobs', 'assess', 'if')

    expect(workflow.dig(true, 'workflow_call', 'inputs', 'reviews', 'default')).to eq('')
    expect(condition).to include("github.event.action != 'synchronize'", "inputs.reviews == ''",
                                 "inputs.reviews == 'copilot'",
                                 "(inputs.reviews == 'private' && github.event.repository.private)")
    expect(workflow.dig('jobs', 'assess', 'steps', 0, 'with', 'reviews')).to eq('${{ inputs.reviews }}')
  end

  it "starts a job for CodeRabbit's comments only when they say it will not review" do
    condition = YAML.load_file(File.expand_path('../.github/workflows/assess.yml', __dir__)).dig('jobs', 'assess', 'if')
    phrases = condition.scan(/contains\(github\.event\.comment\.body, '([^']+)'\)/).flatten

    expect(phrases).to eq(['Review limit reached', 'Reviews paused', 'used all'])
    ['Review limit reached', 'Reviews paused', "You've used all 5 reviews"].each do |notice|
      expect(phrases.any? { |phrase| notice.downcase.include?(phrase.downcase) }).to be(true)
      expect(BotReviews.notice?(notice)).to be(true)
    end
  end
end
