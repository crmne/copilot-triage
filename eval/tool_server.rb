# frozen_string_literal: true

require_relative '../lib/tool_server'

# The same tool implementation, with GitHub reads replaced by fixture data.
# Even live model evaluations cannot access GitHub or publish anything.
class EvaluationTools < TriageTools
  def initialize(example:, **settings)
    super(**settings)
    @example = example
  end

  private

  def api(endpoint)
    issue = @example['candidate']
    release = @example['release']
    case endpoint
    when %r{\Asearch/issues\?}
      { 'items' => [issue].compact, 'total_count' => issue ? 1 : 0 }
    when %r{/issues/\d+/comments\?} then []
    when %r{/issues/(\d+)\z}
      return issue if issue && issue['number'] == Regexp.last_match(1).to_i

      raise IOError, 'No fixture issue with that number.'
    when %r{/releases\?} then [release].compact
    when %r{/releases/(\d+)\z}
      return release if release && release['id'] == Regexp.last_match(1).to_i

      raise IOError, 'No fixture release with that ID.'
    else raise IOError, "Unexpected fixture endpoint: #{endpoint}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  settings = JSON.parse(File.read(ARGV.fetch(0)))
  TriageToolServer.new(EvaluationTools.new(**settings.transform_keys(&:to_sym))).run
end
