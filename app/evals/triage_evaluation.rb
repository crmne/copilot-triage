# frozen_string_literal: true

require 'ruby_llm'
require_relative '../../eval/assessment'

# Checks replies, silence, evidence use, and board decisions against the same corpus.
class TriageEvaluation < RubyLLM::Evaluation
  def perform(input)
    EvaluationAssessment.run(input)
  end

  def assertions
    expected = expected_output
    metrics = output.fetch(:metrics)
    action = output.fetch(:action)
    content = output.fetch(:reply).to_s.downcase

    assert_includes expected.fetch('allowed_actions', [expected.fetch('action')]), action,
                    "Unexpected outcome: #{metrics['reason']}"
    assert_operator metrics.fetch('model_calls'), :<=, expected.fetch('max_calls'), 'Model call budget exceeded'
    assert_operator metrics.fetch('model_calls'), :>=, expected.fetch('min_calls', 0), 'Assessment was not run'
    assert_operator metrics.fetch('evidence_reads'), :>=, expected.fetch('min_evidence_reads', 0),
                    'Missing evidence reads'

    if expected.key?('mute')
      assert_equal expected['mute'], output[:decision]&.fetch('mute', false), 'Stop request was not respected'
    end
    if action != 'silent'
      expected.fetch('contains', []).each do |text|
        assert_includes content, text.downcase
      end
    end
    alternatives = expected.fetch('contains_any', [])
    if alternatives.any?
      assert alternatives.any? { |text|
        content.include?(text.downcase)
      }, 'Missing required reply content'
    end
    return unless expected.key?('next_move')

    assert_includes Array(expected['next_move']), output[:decision]&.dig('next_move'), 'Incorrect board move'
  end
end
