# frozen_string_literal: true

require 'json'
require 'open3'

# The Copilot allowance behind a token. A reserve of premium requests is kept
# back: below it, triage switches to its fallback model and the sweep stops
# requesting Copilot reviews. Unknown quota data never counts as spent.
module CopilotAllowance
  # Premium requests kept back.
  RESERVE = 50

  module_function

  def spent?(token)
    output, _errors, status = Open3.capture3({ 'GH_TOKEN' => token, 'GITHUB_TOKEN' => nil },
                                             'gh', 'api', 'copilot_internal/user')
    quota = status.success? ? JSON.parse(output).dig('quota_snapshots', 'premium_interactions') : nil
    !quota.nil? && !quota['unlimited'] && !quota['overage_permitted'] && quota['remaining'].to_i < RESERVE
  rescue JSON::ParserError
    false
  end
end
