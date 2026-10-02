# frozen_string_literal: true

require_relative '../lib/copilot_review'

RSpec.describe CopilotReview do
  def review(body, commit: 'head', login: 'copilot-pull-request-reviewer')
    { 'author' => { 'login' => login }, 'state' => 'COMMENTED', 'body' => body, 'submittedAt' => '2026-10-01T10:00:00Z',
      'commit' => { 'oid' => commit } }
  end

  let(:closer) do
    <<~BODY
      <!-- ccr-overview-v2 -->

      ## Copilot review overview

      ### 🔵 Needs a closer look

      Unresolved moderate findings remain before approval.

      **Findings:** 1 <picture><source srcset="x.svg"><img src="x.png" alt="Low severity"></picture>

      <details><summary>Pull request overview</summary>Long file-by-file notes.</details>
    BODY
  end

  it 'reads the verdict of the latest Copilot review and whether it covers the latest commit' do
    pull = { 'headRefOid' => 'head', 'reviews' => { 'nodes' => [
      review("### 🟢 Approval recommended\n\nFine.", commit: 'older'),
      review('Looks good to me.', login: 'crmne'), review(closer)
    ] } }

    latest = described_class.latest(pull)
    expect(latest).to include('verdict' => 'closer_look', 'current' => true, 'submitted_at' => '2026-10-01T10:00:00Z')
    expect(latest['summary']).to include('Needs a closer look', 'Findings:** 1 Low severity')
    expect(latest['summary']).not_to include('<', 'file-by-file', 'ccr-overview')
  end

  it 'knows every verdict and marks an older commit stale' do
    verdicts = ['🟢 Approval recommended', '🟡 Changes recommended', '🔵 Needs a closer look'].map do |heading|
      described_class.latest('headRefOid' => 'new', 'reviews' => { 'nodes' => [review("### #{heading}\n\nWhy.")] })
    end

    expect(verdicts.map { |entry| entry['verdict'] }).to eq(%w[approve changes closer_look])
    expect(verdicts.map { |entry| entry['current'] }).to all(be(false))
  end

  it 'has no verdict without a Copilot review, and spots a pending request' do
    copilot = { 'requestedReviewer' => { 'login' => 'copilot-pull-request-reviewer' } }
    pull = { 'reviews' => { 'nodes' => [review('LGTM', login: 'crmne')] },
             'reviewRequests' => { 'nodes' => [copilot] } }

    expect(described_class.latest(pull)).to be_nil
    expect(described_class.requested?(pull)).to be(true)
  end

  it 'withdraws the maintainer and keeps other pending reviewers, but leaves a team request alone' do
    requested = lambda do |*reviewers|
      { 'reviewRequests' => { 'nodes' => reviewers.map { |reviewer| { 'requestedReviewer' => reviewer } } } }
    end
    pull = requested.call({ '__typename' => 'User', 'login' => 'crmne' },
                          { '__typename' => 'Bot', 'login' => 'copilot-pull-request-reviewer' })

    expect(described_class.withdraw_input(pull, 'pr', 'crmne'))
      .to eq(pullRequestId: 'pr', union: false, userLogins: [], botLogins: ['copilot-pull-request-reviewer[bot]'],
             teamSlugs: [])
    expect(described_class.withdraw_input(requested.call({ '__typename' => 'Team' }), 'pr', 'crmne')).to be_nil
    expect(described_class::FIELDS).not_to include('combinedSlug')
  end
end
