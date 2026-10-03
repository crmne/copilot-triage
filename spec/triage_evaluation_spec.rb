# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../app/evals/triage_evaluation'

RSpec.describe TriageEvaluation do
  extend RubyLLM::Evaluation::RSpec

  evaluates described_class
end
