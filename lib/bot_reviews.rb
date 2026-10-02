# frozen_string_literal: true

# What code review bots, such as Copilot and CodeRabbit, found on a pull
# request's latest commit, for the agent to weigh. Each finding keeps its file,
# the bot's own severity label, and a short excerpt; summaries, walkthroughs,
# and collapsed details are left out.
module BotReviews
  REVIEWERS = %w[copilot-pull-request-reviewer coderabbitai].freeze
  SEVERITY = /(?<![[:alpha:]])(critical|high|major|medium|minor|low|trivial|nitpick)(?![[:alpha:]])/i
  # A review that only says the bot could not review, such as when the
  # requester ran out of quota, is no review at all.
  UNREVIEWED = /unable to review|quota limit|reached (?:their|your) (?:monthly )?quota/i
  # The latest reviews with their inline comments, under an alias so it can sit
  # beside CopilotReview::FIELDS in one query.
  FIELDS = 'findings: reviews(last: 20) { nodes { author { login } body submittedAt commit { oid } ' \
           'comments(first: 30) { nodes { path body } } } }'
  MAX_FINDINGS = 30
  EXCERPT = 400

  module_function

  def reviewer?(login)
    REVIEWERS.include?(login.to_s.delete_suffix('[bot]'))
  end

  # { bot => { 'submitted_at', 'reviewed', 'findings' } } for each review bot
  # with a review of the latest commit.
  def current(pull)
    reviews = pull.dig('findings', 'nodes').to_a.select do |review|
      reviewer?(review.dig('author', 'login')) && review.dig('commit', 'oid') == pull['headRefOid']
    end
    reviews.group_by { |review| review.dig('author', 'login').delete_suffix('[bot]') }.to_h do |bot, list|
      findings = list.flat_map { |review| review.dig('comments', 'nodes').to_a }.map { |comment| finding(comment) }
      reviewed = !(findings.empty? && list.all? { |review| review['body'].to_s.match?(UNREVIEWED) })
      [bot, { 'submitted_at' => list.map { |review| review['submittedAt'] }.max, 'reviewed' => reviewed,
              'findings' => findings.first(MAX_FINDINGS) }]
    end
  end

  def finding(comment)
    text = plain(comment['body'])
    { 'path' => comment['path'], 'severity' => text[0, 200][SEVERITY, 1]&.downcase, 'text' => text[0, EXCERPT] }
  end

  def plain(body)
    body.to_s.gsub(/<!--.*?-->/m, '').gsub(%r{<details>.*?</details>}mi, '').gsub(/<[^>]+>/, '')
        .gsub(/!\[[^\]]*\]\([^)]*\)/, '').gsub(/\s+/, ' ').strip
  end
end
