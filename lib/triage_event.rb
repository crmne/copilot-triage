# frozen_string_literal: true

require 'json'
require 'digest'

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

  def maintainer?(association)
    %w[OWNER MEMBER COLLABORATOR].include?(association)
  end

  def bot?(author)
    author && (author['__typename'] == 'Bot' || author['type'] == 'Bot' || author['login']&.end_with?('[bot]'))
  end

  def skip_reason(name, event)
    return if name == 'workflow_dispatch'
    return 'pull requests are outside triage' if event.dig('issue', 'pull_request')
    return unless %w[issue_comment discussion_comment].include?(name)
    return 'only new comments trigger triage' unless event['action'] == 'created'
    return 'comment was posted by a bot' if bot?(event['sender']) || bot?(event.dig('comment', 'user'))
    return 'report is closed' if event.dig('issue', 'state') == 'closed' || event.dig('discussion', 'closed')

    comment = event.fetch('comment')
    return 'a maintainer commented' if maintainer?(comment['author_association']) && !command(comment['body'])

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
