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
  # CodeRabbit says in a comment, not a review, when it will not review a
  # commit: its review limit ran out, or it paused reviews of a busy branch.
  NOTICE = /Review limit reached|You(?:'|’)ve used all .{0,40}reviews|Reviews paused/i
  NEXT_REVIEW = /Next included review available in ([^.*\n]{1,40})/i
  # The latest reviews with their inline comments, under an alias so it can sit
  # beside CopilotReview::FIELDS in one query.
  FIELDS = 'findings: reviews(last: 20) { nodes { author { login } state body submittedAt commit { oid } ' \
           'comments(first: 30) { nodes { path body } } } }'
  MAX_FINDINGS = 30
  EXCERPT = 400

  module_function

  def reviewer?(login)
    REVIEWERS.include?(login.to_s.delete_suffix('[bot]'))
  end

  # { bot => { 'state', 'submitted_at', 'reviewed', 'findings' } } for each
  # review bot with a review of the latest commit; state is its latest verdict,
  # such as APPROVED or CHANGES_REQUESTED.
  def current(pull)
    reviews = pull.dig('findings', 'nodes').to_a.select do |review|
      reviewer?(review.dig('author', 'login')) && review.dig('commit', 'oid') == pull['headRefOid']
    end
    reviews.group_by { |review| review.dig('author', 'login').delete_suffix('[bot]') }.to_h do |bot, list|
      findings = list.flat_map { |review| review.dig('comments', 'nodes').to_a }.map { |comment| finding(comment) }
      reviewed = !(findings.empty? && list.all? { |review| review['body'].to_s.match?(UNREVIEWED) })
      latest = list.max_by { |review| review['submittedAt'].to_s }
      [bot, { 'state' => latest['state'], 'submitted_at' => latest['submittedAt'], 'reviewed' => reviewed,
              'findings' => findings.first(MAX_FINDINGS) }]
    end
  end

  def notice?(body)
    body.to_s.match?(NOTICE)
  end

  # { bot => { 'reviewed' => false, 'unavailable' => why } } for each review
  # bot whose latest comment says it will not review the latest commit, and
  # that has not reviewed it anyway.
  def unavailable(pull)
    reviewed = current(pull)
    notices = pull.dig('comments', 'nodes').to_a.select do |comment|
      reviewer?(comment.dig('author', 'login')) && notice?(comment['body'])
    end
    notices.group_by { |comment| comment.dig('author', 'login').delete_suffix('[bot]') }.filter_map do |bot, list|
      next if reviewed.dig(bot, 'reviewed')

      body = list.last['body'].to_s
      wait = body[NEXT_REVIEW, 1]&.strip
      why = if body.match?(/Reviews paused/i) then 'reviews paused on this branch'
            elsif wait then "review limit reached; next review in #{wait}"
            else 'review limit reached'
            end
      [bot, { 'reviewed' => false, 'unavailable' => why }]
    end.to_h
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
