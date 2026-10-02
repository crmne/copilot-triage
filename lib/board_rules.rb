# frozen_string_literal: true

require_relative 'copilot_review'
require_relative 'triage_event'

# Where an issue or pull request belongs, from GitHub facts alone. The sweep
# places every open item with these rules, and triage uses them for the
# maintainer's own pull requests, which need no model.
module BoardRules
  module_function

  # Returns a column key, or :agent when Copilot asks for a closer look, which
  # only triage can judge.
  def pull_request_column(pull)
    own = maintainer?(pull)
    yours_or_theirs = own ? 'do' : 'theirs'
    return yours_or_theirs if pull['isDraft']

    checks = pull.dig('commits', 'nodes', 0, 'commit', 'statusCheckRollup', 'state')
    green = [nil, 'SUCCESS'].include?(checks)
    ready = green && pull['mergeable'] == 'MERGEABLE'
    return yours_or_theirs if %w[FAILURE ERROR].include?(checks) || pull['mergeable'] == 'CONFLICTING' ||
                              (!own && pull['reviewDecision'] == 'CHANGES_REQUESTED')
    return 'sign_off' if pull['reviewDecision'] == 'APPROVED' && ready

    reviewer = reviewer_state(pull)
    return yours_or_theirs if reviewer == 'CHANGES_REQUESTED'
    return 'sign_off' if reviewer == 'APPROVED' && ready
    return 'theirs' if CopilotReview.requested?(pull) || %w[PENDING EXPECTED].include?(checks)

    review = CopilotReview.latest(pull)
    case review && review['current'] && review['verdict']
    when 'approve' then ready ? 'sign_off' : 'theirs'
    when 'changes' then yours_or_theirs
    when 'closer_look' then own ? own_column(ready) : :agent
    else own ? own_column(ready) : 'do'
    end
  end

  # An issue with an open pull request that would close it follows that pull
  # request's card, so the two finish together.
  def issue_column(issue, current, status_updated_at, linked_column: nil)
    linked = issue.dig('closedByPullRequestsReferences', 'totalCount').to_i.positive?
    return linked_column || 'theirs' if linked

    human = issue.dig('comments', 'nodes').to_a.reject { |comment| TriageEvent.bot?(comment['author']) }.last
    yours = bug?(issue) ? 'do' : 'decide'
    if current.nil?
      return 'not_now' if maintainer?(issue) && (human.nil? || maintainer?(human))

      return human && maintainer?(human) ? 'theirs' : yours
    end
    return unless current == 'theirs' && human && !maintainer?(human)

    yours if status_updated_at.nil? || human.fetch('createdAt') > status_updated_at
  end

  def own_column(ready)
    ready ? 'sign_off' : 'do'
  end

  # The latest decisive review by a bot other than Copilot, such as CodeRabbit,
  # on the latest commit: APPROVED, CHANGES_REQUESTED, or nil.
  def reviewer_state(pull)
    reviews = pull.dig('reviews', 'nodes').to_a.select do |review|
      bot_login?(review.dig('author', 'login')) && !CopilotReview.copilot?(review['author']) &&
        review.dig('commit', 'oid') == pull['headRefOid'] && %w[APPROVED CHANGES_REQUESTED].include?(review['state'])
    end
    reviews.last&.fetch('state')
  end

  def bot_login?(login)
    login.to_s.end_with?('[bot]') || %w[coderabbitai].include?(login.to_s)
  end

  def bug?(issue)
    issue.dig('labels', 'nodes').to_a.any? { |label| label['name'] == 'bug' }
  end

  def maintainer?(node)
    TriageEvent.maintainer?(node['authorAssociation'])
  end
end
