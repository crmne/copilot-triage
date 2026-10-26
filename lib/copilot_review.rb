# frozen_string_literal: true

require_relative 'bot_reviews'

# Copilot code review as GitHub reports it: a review by the Copilot reviewer bot
# whose body opens with a verdict, for one commit. Only a verdict on the pull
# request's latest commit counts; a new push makes the old one stale.
module CopilotReview
  LOGIN = 'copilot-pull-request-reviewer'
  VERDICTS = { '🟢' => 'approve', '🟡' => 'changes', '🔵' => 'closer_look', '🔴' => 'changes' }.freeze
  # GraphQL fields every reader of a pull request asks for.
  FIELDS = 'headRefOid ' \
           'reviewRequests(first: 20) { nodes { requestedReviewer { __typename ... on Bot { login } ' \
           '... on User { login } } } } ' \
           'reviews(last: 20) { nodes { author { login } state body submittedAt commit { oid } } }'

  module_function

  # The latest Copilot review: its verdict, whether it covers the latest commit,
  # and its text without markup. nil when Copilot never reviewed.
  def latest(pull)
    review = pull.dig('reviews', 'nodes').to_a.reverse.find { |entry| copilot?(entry['author']) }
    return unless review

    body = review['body'].to_s
    return { 'verdict' => nil, 'reviewed' => false, 'summary' => summary(body) } if body.match?(BotReviews::UNREVIEWED)

    { 'verdict' => VERDICTS.find { |icon, _| body.match?(/^#+\s*#{icon}/) }&.last,
      'current' => review.dig('commit', 'oid') == pull['headRefOid'], 'submitted_at' => review['submittedAt'],
      'summary' => summary(body) }
  end

  # Copilot reviewed an earlier commit, so triage once judged the pull request
  # worth a review, but not the latest one.
  def stale?(pull)
    reviews = pull.dig('reviews', 'nodes').to_a.select { |entry| copilot?(entry['author']) }
    reviews.any? && reviews.none? { |entry| entry.dig('commit', 'oid') == pull['headRefOid'] }
  end

  # Whether the policy's pull_requests.reviews lets Copilot review here:
  # copilot always, private only when the block finds the repository private,
  # off never. Public repositories get free reviews elsewhere, such as
  # CodeRabbit, so private keeps Copilot's, billed to its owner, to private ones.
  def wanted?(policy)
    mode = policy.fetch('reviews', 'copilot')
    mode = 'off' if mode == false # YAML reads a bare off as false
    unless %w[copilot private off].include?(mode)
      raise ArgumentError, 'pull_requests.reviews must be copilot, private, or off'
    end

    mode == 'copilot' || (mode == 'private' && yield)
  end

  def requested?(pull)
    reviewers(pull).any? { |reviewer| copilot?(reviewer) }
  end

  def reviewers(pull)
    pull.dig('reviewRequests', 'nodes').to_a.filter_map { |request| request['requestedReviewer'] }
  end

  # Review requests go through GraphQL's requestReviewsByLogin. REST cannot
  # remove a reviewer while a bot such as Copilot is among the requested ones,
  # so a withdrawal sets the requested reviewers to those still pending,
  # minus the maintainer, without adding anyone back. Naming a team needs the
  # read:org scope, so with a team pending there is no withdrawal (nil).
  REQUEST_MUTATION = 'mutation($input: RequestReviewsByLoginInput!) ' \
                     '{ requestReviewsByLogin(input: $input) { clientMutationId } }'

  def request_input(pull_id, login)
    { pullRequestId: pull_id, userLogins: [login], union: true }
  end

  def copilot_input(pull_id)
    { pullRequestId: pull_id, botLogins: ["#{LOGIN}[bot]"], union: true }
  end

  def withdraw_input(pull, pull_id, login)
    pending = reviewers(pull).group_by { |reviewer| reviewer['__typename'] }
    return if pending.key?('Team')

    users = pending.fetch('User', []).map { |user| user['login'] } - [login]
    bots = pending.fetch('Bot', []).map { |bot| "#{bot['login'].delete_suffix('[bot]')}[bot]" }
    { pullRequestId: pull_id, union: false, userLogins: users, botLogins: bots, teamSlugs: [] }
  end

  def copilot?(author)
    author.to_h['login'].to_s.delete_suffix('[bot]') == LOGIN
  end

  # The verdict, its reason, and the findings line, without HTML, images, or the
  # long file-by-file overview.
  def summary(body)
    text = body.split(/<details>/i, 2).first.to_s
    text.gsub(/<!--.*?-->/m, '').gsub(%r{<picture>.*?</picture>}m) { |picture| picture[/alt="([^"]+)"/, 1].to_s }
        .gsub(/<[^>]+>/, '').gsub(/\n{3,}/, "\n\n").strip[0, 1500]
  end
end
