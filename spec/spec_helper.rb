# frozen_string_literal: true

require 'rspec'
require 'tmpdir'
require 'fileutils'

module AgentToolHelpers
  def agent_reads(assessment, *references)
    tools = assessment.send(:evidence_tools)
    references.each do |reference|
      offset = 0
      loop do
        result = tools.call('read_evidence', { 'reference' => reference, 'offset' => offset })
        raise result.inspect if result[:isError]

        offset = JSON.parse(result.fetch(:content).first.fetch(:text))['next_offset']
        break unless offset
      end
    end
    assessment.instance_variable_set(:@tool_ledger, tools.ledger)
  end
end

RSpec.configure do |config|
  config.include AgentToolHelpers
  config.around do |example|
    Dir.mktmpdir('triage-repository-') do |directory|
      FileUtils.cp_r(Dir.glob(File.join(__dir__, 'fixtures', '*')), directory)
      Dir.chdir(directory) { example.run }
    end
  end
end
