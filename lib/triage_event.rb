# frozen_string_literal: true

require 'json'
require 'digest'
require_relative 'bot_reviews'

# Checks available in the event payload, before checkout, caches, or CLI setup.
module TriageEvent
  module_function

  def prose(body)
    body.to_s.gsub(/```.*?```|`[^`]*`|^>[^\n]*$/m, '').strip
  end

  def command(body)
    prose(body)[%r{\A/triage(?:\s+(reassess|mute|unmute))?\s*\z}i, 1]&.downcase ||
      ('reassess' if prose(body).match?(%r{\A/triage\s*\z}i))
  end

  def review_skip_reason(event)
    return 'only submitted reviews trigger triage' unless event['action'] == 'submitted'
    return 'only review bots such as Copilot and CodeRabbit trigger triage' unless
      BotReviews.reviewer?(event.dig('review', 'user', 'login'))
    return 'reviews of forked pull requests are sent by the board sweep' unless
      event.dig('pull_request', 'head', 'repo', 'full_name') == event.dig('repository', 'full_name')

    nil
  end

  def maintainer?(association)
    %w[OWNER MEMBER COLLABORATOR].include?(association)
  end

  def bot?(author)
    author && (author['__typename'] == 'Bot' || author['type'] == 'Bot' || author['login']&.end_with?('[bot]'))
  end

  PULL_REQUEST_ACTIONS = %w[opened reopened ready_for_review synchronize closed].freeze

  # Pull request events pass through; the policy decides whether to triage them.
  # Of review events, only review bots' reviews of same-repository pull requests
  # count: review runs for forks get no secrets, so the board sweep sends those.
  def skip_reason(name, event)
    return if name == 'workflow_dispatch'
    return review_skip_reason(event) if name == 'pull_request_review'
    if %w[pull_request pull_request_target].include?(name) && !PULL_REQUEST_ACTIONS.include?(event['action'])
      return 'only opened, reopened, ready, updated, or closed pull requests trigger triage'
    end
    return unless %w[issue_comment discussion_comment].include?(name)
    return 'only new comments trigger triage' unless event['action'] == 'created'
    return 'comment was posted by a bot' if bot?(event['sender']) || bot?(event.dig('comment', 'user'))
    return 'report is closed' if event.dig('issue', 'state') == 'closed' || event.dig('discussion', 'closed')

    nil
  end
end

if $PROGRAM_NAME == __FILE__
  event = JSON.parse(File.read(ENV.fetch('GITHUB_EVENT_PATH')))
  reason = TriageEvent.skip_reason(ENV.fetch('GITHUB_EVENT_NAME', nil), event)
  thread = (event['discussion'] && (event.dig('comment', 'parent_id') || event.dig('comment', 'id'))) || 'report'
  File.open(ENV.fetch('GITHUB_OUTPUT'), 'a') do |file|
    file.puts("eligible=#{reason.nil?}\nthread=#{thread}")
  end
  puts "Skipped: #{reason}." if reason
end
