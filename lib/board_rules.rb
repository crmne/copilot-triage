# frozen_string_literal: true

require_relative 'copilot_review'
require_relative 'triage_event'

# Where an issue or pull request belongs, from GitHub facts alone. The sweep
# places every open item with these rules, and triage uses them for the
# maintainer's own pull requests, which need no model.
module BoardRules
  module_function

  # Returns a column key, or :agent when Copilot asks for a closer look or
  # another review bot left findings, which only triage can judge.
  def pull_request_column(pull)
    own = maintainer?(pull)
    yours_or_theirs = own ? 'do' : 'theirs'
    return yours_or_theirs if pull['isDraft']

    checks = check_state(pull.dig('commits', 'nodes', 0, 'commit', 'statusCheckRollup'))
    green = [nil, 'SUCCESS'].include?(checks)
    ready = green && pull['mergeable'] == 'MERGEABLE'
    return yours_or_theirs if %w[FAILURE ERROR].include?(checks) || pull['mergeable'] == 'CONFLICTING' ||
                              (!own && pull['reviewDecision'] == 'CHANGES_REQUESTED' && !pushed_since_changes?(pull))
    return 'sign_off' if pull['reviewDecision'] == 'APPROVED' && ready

    reviewer = reviewer_state(pull)
    # A bot asks for changes even for findings that should not hold a pull
    # request back, so the agent weighs them; its approval of a ready pull
    # request is enough.
    return own ? 'do' : :agent if reviewer == 'CHANGES_REQUESTED'
    return 'sign_off' if reviewer == 'APPROVED' && ready
    return 'theirs' if CopilotReview.requested?(pull) || %w[PENDING EXPECTED].include?(checks)

    review = CopilotReview.latest(pull)
    case review && review['current'] && review['verdict']
    when 'approve' then ready ? 'sign_off' : 'theirs'
    when 'changes' then yours_or_theirs
    when 'closer_look' then own ? own_column(ready) : :agent
    else
      return own_column(ready) if own

      findings?(pull) ? :agent : 'do'
    end
  end

  # An issue with an open pull request that would close it follows that pull
  # request's card, so the two finish together. A proposed closure in Sign off
  # is stale once the issue is reopened or the maintainer joins: it is placed
  # again from the conversation.
  def issue_column(issue, current, status_updated_at, linked_column: nil)
    linked = issue.dig('closedByPullRequestsReferences', 'totalCount').to_i.positive?
    return linked_column || 'theirs' if linked

    comments = issue.dig('comments', 'nodes').to_a
    human = comments.reject { |comment| TriageEvent.bot?(comment['author']) }.last
    yours = bug?(issue) ? 'do' : 'decide'
    if current == 'sign_off'
      return unless changed_since?(issue, status_updated_at, comments)

      return human && maintainer?(human) ? 'theirs' : yours
    end
    if current.nil?
      return 'not_now' if maintainer?(issue) && (human.nil? || maintainer?(human))

      return human && maintainer?(human) ? 'theirs' : yours
    end
    return unless current == 'theirs' && human && !maintainer?(human)

    yours if status_updated_at.nil? || human.fetch('createdAt') > status_updated_at
  end

  # The maintainer's comment is the latest from a person, and the card was
  # placed after it, so triage placed it by what they said. A later push, or a
  # commit rebased since, means the author has answered.
  def placed_by_maintainer?(pull, since)
    human = pull.dig('comments', 'nodes').to_a.reject { |comment| TriageEvent.bot?(comment['author']) }.last
    return false unless since && human && maintainer?(human) && since > human.fetch('createdAt')

    committed = pull.dig('commits', 'nodes', 0, 'commit', 'committedDate')
    committed.nil? || committed < human.fetch('createdAt')
  end

  # Triage's own jobs, and runs cancelled or skipped, say nothing about the
  # change, so they are left out of the checks' state.
  OWN_CHECKS = %w[assess sweep].freeze
  FAILED = %w[FAILURE TIMED_OUT STARTUP_FAILURE ACTION_REQUIRED ERROR].freeze

  def check_state(rollup)
    return rollup&.dig('state') unless rollup&.key?('contexts')

    states = rollup.dig('contexts', 'nodes').to_a.filter_map do |check|
      next if OWN_CHECKS.include?(check['name'])

      check['context'] ? check['state'] : (check['conclusion'] || 'PENDING')
    end
    return 'FAILURE' if states.intersect?(FAILED)
    return 'PENDING' if states.intersect?(%w[PENDING EXPECTED])

    states.empty? ? nil : 'SUCCESS'
  end

  # The author pushed after a person asked for changes: it is the reviewer's
  # move again.
  def pushed_since_changes?(pull)
    asked = pull.dig('reviews', 'nodes').to_a.select do |review|
      review['state'] == 'CHANGES_REQUESTED' && !bot_login?(review.dig('author', 'login'))
    end.last
    asked && asked.dig('commit', 'oid') != pull['headRefOid']
  end

  # Another review bot, such as CodeRabbit, commented on the latest commit:
  # whether its findings matter is the agent's call.
  def findings?(pull)
    pull.dig('reviews', 'nodes').to_a.any? do |review|
      BotReviews.reviewer?(review.dig('author', 'login')) && !CopilotReview.copilot?(review['author']) &&
        review['state'] == 'COMMENTED' && review.dig('commit', 'oid') == pull['headRefOid']
    end
  end

  # When the latest bot review of the latest commit was submitted, so the
  # sweep sends each review to the agent once.
  def reviewed_at(pull)
    reviews = pull.dig('reviews', 'nodes').to_a.select do |review|
      BotReviews.reviewer?(review.dig('author', 'login')) && review.dig('commit', 'oid') == pull['headRefOid']
    end
    reviews.filter_map { |review| review['submittedAt'] }.max
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

  # The issue was reopened, or the maintainer commented, after the card was
  # placed: a proposal made before is stale, but a placement made after stands.
  def changed_since?(issue, since, comments)
    return issue['stateReason'] == 'REOPENED' || comments.any? { |comment| maintainer?(comment) } if since.nil?

    reopened = issue.dig('reopened', 'nodes').to_a.filter_map { |event| event['createdAt'] }.max
    answered = comments.select { |comment| maintainer?(comment) }.filter_map { |comment| comment['createdAt'] }.max
    [reopened, answered].compact.any? { |time| time > since }
  end

  # A one-line next step for a card the sweep moved, so it never keeps one
  # written for its old column.
  def reason(node, column, pull:)
    return issue_reason(node, column) unless pull

    checks = check_state(node.dig('commits', 'nodes', 0, 'commit', 'statusCheckRollup'))
    case column
    when 'sign_off' then 'Approved, green, and mergeable: merge it'
    when 'theirs'
      if node['isDraft'] then 'Draft: the author finishes it'
      elsif node['mergeable'] == 'CONFLICTING' then 'Conflicts with the base branch: the author rebases'
      elsif %w[FAILURE ERROR].include?(checks) then 'Checks fail: the author fixes them'
      elsif node['reviewDecision'] == 'CHANGES_REQUESTED' || reviewer_state(node) == 'CHANGES_REQUESTED'
        'Changes requested: the author has the next step'
      elsif %w[PENDING EXPECTED].include?(checks) then 'Checks or a review are still running'
      else 'Waiting on the author'
      end
    when 'do' then do_reason(node, checks)
    end
  end

  def do_reason(node, checks)
    if maintainer?(node)
      %w[FAILURE ERROR].include?(checks) ? 'Your change fails its checks: fix them' : 'Finish your change'
    elsif pushed_since_changes?(node) then 'The author pushed after your review: review again'
    else
      'Read the change'
    end
  end

  def issue_reason(issue, column)
    if issue.dig('closedByPullRequestsReferences', 'totalCount').to_i.positive?
      number = issue.dig('closedByPullRequestsReferences', 'nodes', 0, 'number')
      return "Follows pull request ##{number}" if number
    end
    { 'theirs' => 'Waiting on the reporter or author', 'do' => 'They answered: read the reply and act',
      'decide' => 'They answered: read the reply and decide' }[column]
  end

  # Something happened after a card was put in Done by hand or archived: the
  # item was reopened or a person commented, so it needs placing again.
  def revived?(node, since)
    return true if since.nil?

    reopened = node.dig('reopened', 'nodes').to_a.filter_map { |event| event['createdAt'] }.max
    human = node.dig('comments', 'nodes').to_a.reject { |comment| TriageEvent.bot?(comment['author']) }
                .filter_map { |comment| comment['createdAt'] }.max
    [reopened, human].compact.any? { |time| time > since }
  end

  def bug?(issue)
    issue.dig('labels', 'nodes').to_a.any? { |label| label['name'] == 'bug' }
  end

  def maintainer?(node)
    TriageEvent.maintainer?(node['authorAssociation'])
  end
end
