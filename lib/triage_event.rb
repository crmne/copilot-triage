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

  def acknowledgement?(body)
    body.to_s.strip.match?(/\A(?:thanks(?: a lot| so much)?|thank you(?: so much)?|\+1|👍|🙏|me too)[.!\s]*\z/i)
  end

  def stop_requested?(body)
    text = prose(body)
    return false if text.match?(/\b(?:don't|do not|never)\s+(?:stop|disable|silence|mute|remove|turn off)\b/i)

    text.match?(/\b(?:stop|disable|silence|mute|remove|turn off)\b[^.!?\n]{0,100}\b(?:copilot|triage bot)\b/i) ||
      text.match?(/\b(?:copilot|triage bot)\b[^.!?\n]{0,100}\b(?:stop|disabled|silenced|muted|removed)\b/i)
  end

  def question?(body)
    text = prose(body).gsub(%r{https?://\S+}, '')
    question = /\A(?:how\ (?:do|can|would)|what\ (?:is|are)|can\ (?:you|someone)|please\ (?:help|explain))\b/ix
    text.include?('?') || text.match?(question)
  end

  def evidence_signals(body)
    text = body.to_s.gsub(/^>[^\n]*$/, '')
    patterns = [
      /\bv?\d+\.\d+(?:\.\d+)?(?:[-+][\w.]+)?\b/i,
      /\b\d+(?:\.\d+)?\s*(?:%|ms\b|seconds?\b|secs?\b|MB\b|GB\b)/i,
      /\b(?:windows(?:\s+\d+)?|macos|linux|ubuntu|fedora|arch|wayland|x11)\b/i,
      /\b(?:error|exception|panic|traceback|failed|regression|workaround|bisected|steps to reproduce)\b[^\n]{0,160}/i,
      /\b(?:fixed by|root cause|backtrace|reproduction|profile|log output)\b[^\n]{0,160}/i,
      /\b(?:now|started|still)\s+(?:crash\w*|freez\w*|fail\w*)[^\n]{0,120}/i,
      /^\s*\d+[.)]\s+[^\n]{3,160}/
    ]
    patterns.flat_map { |pattern| text.scan(pattern) }.map do |signal|
      Digest::SHA256.hexdigest(signal.downcase.gsub(/\s+/, ' ').strip)
    end.uniq
  end

  def new_failure?(body)
    prose(body).match?(/\b(?:error|exception|panic|traceback|regression|crash\w*|fail\w*|freez\w*)\b/i)
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
    return 'an acknowledgement needs no assessment' if acknowledgement?(comment['body'])

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
