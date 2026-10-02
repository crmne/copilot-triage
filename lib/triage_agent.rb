# frozen_string_literal: true

require 'ruby_llm'
require_relative 'triage_tools'

# The triage agent for any model RubyLLM can reach: a provider API key, an
# OpenAI-compatible endpoint, or a local model. It gets the same instructions
# and tools as the Copilot CLI agent, and the same limits.
#
#   agent = TriageAgent.new(toolbox:, system_prompt:, model: 'gpt-5.6-luna')
#   agent = TriageAgent.new(toolbox:, system_prompt:, model: 'openai/gpt-oss-120b', provider: :openrouter,
#                           tool_choice: :auto)
#   agent.triage(report)
#   toolbox.ledger['decision']
class TriageAgent < RubyLLM::Agent
  class Exhausted < StandardError; end

  MAX_TURNS = 20
  TIME_LIMIT = 120

  # The toolbox does the work: it enforces the evidence budget, keeps the
  # ledger, and validates the decision. Each tool takes its description and
  # schema from it, so both engines show the model exactly the same tools.
  class Tool < RubyLLM::Tool
    def self.tool_name
      name.split('::').last.gsub(/\B([A-Z])/, '_\1').downcase
    end

    def initialize(toolbox)
      super()
      @toolbox = toolbox
    end

    def description
      definition.fetch(:description)
    end

    def parameters_schema
      definition.fetch(:inputSchema)
    end

    def execute(**arguments)
      @toolbox.call(name, arguments.transform_keys(&:to_s)).dig(:content, 0, :text)
    end

    private

    def definition
      @definition ||= @toolbox.definitions.find { |tool| tool[:name] == name }
    end
  end

  class SearchRepository < Tool; end
  class SearchIssues < Tool; end
  class ListReleases < Tool; end
  class ReadEvidence < Tool; end
  class SubmitDecision < Tool; end

  inputs :toolbox, :system_prompt, :tool_choice

  instructions { system_prompt }
  tools do
    [SearchRepository, SearchIssues, ListReleases, ReadEvidence, SubmitDecision].map { |tool| tool.new(toolbox) }
  end
  # Requiring a tool call keeps most models on task, but OpenRouter's hosts of
  # gpt-oss answer a required call with an empty error turn, so it can be
  # relaxed; a model that stops without submitting is reminded once.
  tool_options { { choice: tool_choice || :required } }
  max_output_tokens 4000

  def initialize(toolbox:, tool_choice: nil, **)
    @toolbox = toolbox
    super
  end

  # Drives the loop one move at a time and stops as soon as the decision is
  # submitted, so the model never spends a turn on closing remarks.
  def triage(report)
    ask_later(report)
    deadline = now + TIME_LIMIT
    reminded = false
    until submitted?
      if complete?
        break if reminded

        ask_later(REMINDER)
        reminded = true
      end
      raise Exhausted, "no decision after #{MAX_TURNS} model turns" if turns >= MAX_TURNS
      raise Exhausted, "no decision within #{TIME_LIMIT} seconds" if now > deadline

      step
    end
  end

  REMINDER = 'Finish now by calling submit_decision with your decision. A plain-text answer is not a submission.'

  def submitted?
    @toolbox.ledger.key?('decision')
  end

  def turns
    messages.count { |message| message.role == :assistant }
  end

  private

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
