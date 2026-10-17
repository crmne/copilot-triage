# frozen_string_literal: true

require 'yaml'

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
end
