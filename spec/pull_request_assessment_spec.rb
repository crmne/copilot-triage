# frozen_string_literal: true

require_relative '../lib/assessment'

RSpec.describe IssueAssessment, 'with a pull request' do
  let(:environment) do
    { 'GITHUB_REPOSITORY' => 'crmne/ruby_llm', 'TRIAGE_NUMBER' => '77', 'TRIAGE_KIND' => 'pull_request',
      'TRIAGE_CONFIG' => 'pr-triage.yml', 'COPILOT_GITHUB_TOKEN' => 'copilot-token',
      'TRIAGE_STATE_DIR' => 'state', 'TRIAGE_DEBOUNCE_SECONDS' => '0' }
  end
  let(:policy) { {} }
  let(:assessment) { described_class.new(environment) }
  let(:item) do
    { 'id' => 'pr-id', 'title' => 'Add streaming retries', 'body' => 'Retries dropped streams.', 'closed' => false,
      'author' => { 'login' => 'contributor' }, 'authorAssociation' => 'CONTRIBUTOR', 'isDraft' => false,
      'headRefOid' => 'a' * 40, 'changedFiles' => 2, 'additions' => 120, 'deletions' => 3,
      'files' => { 'nodes' => [
        { 'path' => 'lib/ruby_llm/stream.rb', 'additions' => 118, 'deletions' => 3, 'changeType' => 'MODIFIED' },
        { 'path' => 'spec/stream_spec.rb', 'additions' => 2, 'deletions' => 0, 'changeType' => 'ADDED' }
      ] }, 'assignees' => { 'totalCount' => 0 }, 'comments' => { 'nodes' => [] } }
  end
  let(:labels) { [{ 'id' => 'enhancement-id', 'name' => 'enhancement' }] }
  let(:decision) do
    { labels: ['enhancement'], reply: nil, comment: nil, sources: [], related_issue: nil, relationship: nil,
      mute: false, review: true, out_of_scope: false }
  end

  def run_with(event_name: 'workflow_dispatch', action: nil)
    if action
      File.write('event.json', JSON.generate('action' => action, 'pull_request' => { 'number' => 77 }))
      environment.merge!('GITHUB_EVENT_NAME' => event_name, 'GITHUB_EVENT_PATH' => 'event.json')
    end
    runner = described_class.new(environment)
    allow(runner).to receive_messages(read_report: [item, labels])
    allow(runner).to receive(:ask_copilot) { JSON.generate(decision) }
    allow(runner).to receive(:mutate)
    allow(runner).to receive(:puts)
    runner.run
    runner
  end

  before do
    config = YAML.safe_load_file('triage.yml').merge('pull_requests' => policy)
    File.write('pr-triage.yml', YAML.dump(config))
  end

  it 'labels the pull request and requests a Copilot review with the review token' do
    runner = run_with

    expect(runner).to have_received(:mutate).with('addLabelsToLabelable', labelableId: 'pr-id',
                                                                          labelIds: ['enhancement-id'])
    expect(runner).to have_received(:mutate).with(
      'requestReviewsByLogin', token: 'copilot-token', pullRequestId: 'pr-id',
                               botLogins: [described_class::COPILOT_REVIEWER], union: true
    )
    expect(runner).not_to be_failed
  end

  it 'requests no Copilot review for a change under 100 lines of code, however much else it changes' do
    item['files']['nodes'] = [
      { 'path' => 'lib/ruby_llm/stream.rb', 'additions' => 60, 'deletions' => 3, 'changeType' => 'MODIFIED' },
      { 'path' => 'docs/streaming.md', 'additions' => 300, 'deletions' => 0, 'changeType' => 'MODIFIED' },
      { 'path' => 'config/locales/de.yml', 'additions' => 200, 'deletions' => 0, 'changeType' => 'MODIFIED' },
      { 'path' => 'Gemfile.lock', 'additions' => 90, 'deletions' => 40, 'changeType' => 'MODIFIED' }
    ]
    runner = run_with

    expect(runner).not_to have_received(:mutate).with('requestReviewsByLogin', anything)
    expect(runner).to have_received(:ask_copilot).with(include('not used on changes under 100 lines of code'))
  end

  it 'gives the agent every review bot finding on the latest commit, and no stale ones' do
    finding = lambda do |login, commit, body|
      { 'author' => { 'login' => login }, 'body' => '', 'submittedAt' => '2026-10-02T10:00:00Z',
        'commit' => { 'oid' => commit },
        'comments' => { 'nodes' => [{ 'path' => 'lib/ruby_llm/stream.rb', 'body' => body }] } }
    end
    item['findings'] = { 'nodes' => [
      finding.call('coderabbitai', 'a' * 40,
                   "_⚠️ Potential issue_ | _🟠 Major_\n\n**Race on retry.** <details>long</details>"),
      finding.call('coderabbitai', 'b' * 40, 'Stale finding on an older commit'),
      finding.call('copilot-pull-request-reviewer', 'a' * 40, 'High: the retry loop never stops.')
    ] }
    runner = run_with

    expect(runner).to have_received(:ask_copilot) do |prompt|
      expect(prompt).to include('"other_reviews":{"coderabbitai":', '"severity":"major"', 'Race on retry.')
      expect(prompt).not_to include('Stale finding', 'long')
    end
  end

  context 'when reviews are off, written as a bare YAML off' do
    let(:policy) { { 'reviews' => false } }

    it 'requests no Copilot review' do
      expect(run_with).not_to have_received(:mutate).with('requestReviewsByLogin', anything)
    end
  end

  it "ignores CodeRabbit's summary in the description, so its edit does not abandon the assessment" do
    summary = "\n\n<!-- This is an auto-generated comment: release notes by coderabbit.ai -->\n## Summary\n" \
              '<!-- end of auto-generated comment: release notes by coderabbit.ai -->'
    runner = described_class.new(environment)
    raw = item.merge('body' => "Retries dropped streams.#{summary}")
    repository = { 'id' => 'repo', 'labels' => { 'nodes' => labels }, 'pullRequest' => raw }
    allow(runner).to receive(:github).and_return('data' => { 'repository' => repository })

    expect(runner.send(:read_report).first['body']).to eq('Retries dropped streams.')
  end

  it 'prefers a dedicated review token' do
    environment['TRIAGE_REVIEW_TOKEN'] = 'owner-review-token'

    expect(run_with).to have_received(:mutate).with('requestReviewsByLogin',
                                                    hash_including(token: 'owner-review-token'))
  end

  it 'shows the agent the changed files in one compact line each' do
    runner = run_with

    prompt = runner.send(:build_prompt, item, labels)
    expect(prompt).to include('pull request in crmne/ruby_llm', 'MODIFIED lib/ruby_llm/stream.rb +118 -3',
                              '"changedFiles":2', 'also submit review and out_of_scope')
    expect(runner.send(:system_prompt)).to include('## Pull requests')
    expect(runner.send(:tools_settings, Dir.pwd)).to include(pull_request: 77)
  end

  it 'requests a review only once per commit' do
    run_with
    second = run_with

    expect(second).not_to have_received(:mutate).with('requestReviewsByLogin', anything)
  end

  it 'asks for a new review after a push, without the model, when a review was wanted' do
    run_with
    item['headRefOid'] = 'b' * 40
    pushed = run_with(event_name: 'pull_request_target', action: 'synchronize')

    expect(pushed).not_to have_received(:ask_copilot)
    expect(pushed).to have_received(:mutate).with('requestReviewsByLogin', hash_including(pullRequestId: 'pr-id'))
    expect(pushed).to have_received(:puts).with('Skipped: a new push needs no new assessment.')
  end

  it 'leaves a push alone when the agent saw no need for a review' do
    decision[:review] = false
    run_with
    item['headRefOid'] = 'b' * 40
    pushed = run_with(event_name: 'pull_request_target', action: 'synchronize')

    expect(pushed).not_to have_received(:mutate).with('requestReviewsByLogin', anything)
  end

  context 'with reviews turned off' do
    let(:policy) { { 'reviews' => 'off' } }

    it 'never requests one' do
      expect(run_with).not_to have_received(:mutate).with('requestReviewsByLogin', anything)
    end
  end

  it 'only explains an out-of-scope change by default' do
    decision.merge!(review: false, out_of_scope: true, comment: 'The project does not ship a GUI.')
    runner = run_with

    expect(runner).to have_received(:mutate).with('addComment', subjectId: 'pr-id',
                                                                body: start_with('The project does not ship a GUI.'))
    expect(runner).not_to have_received(:mutate).with('closePullRequest', anything)
  end

  context 'when out-of-scope changes close' do
    let(:policy) { { 'out_of_scope' => 'close' } }

    before { decision.merge!(review: false, out_of_scope: true, comment: 'The project does not ship a GUI.') }

    it 'closes after the explanation' do
      runner = run_with

      expect(runner).to have_received(:mutate).with('addComment', anything).ordered
      expect(runner).to have_received(:mutate).with('closePullRequest', pullRequestId: 'pr-id').ordered
    end

    it "never closes a maintainer's own pull request" do
      item['authorAssociation'] = 'OWNER'

      expect(run_with).not_to have_received(:mutate).with('closePullRequest', anything)
    end
  end

  it 'reports a failed review request without undoing the published triage' do
    runner = described_class.new(environment)
    allow(runner).to receive_messages(read_report: [item, labels], ask_copilot: JSON.generate(decision))
    allow(runner).to receive(:puts)
    allow(runner).to receive(:mutate)
    allow(runner).to receive(:mutate).with('requestReviewsByLogin', anything).and_raise('GitHub request failed')
    runner.run

    expect(runner).to have_received(:mutate).with('addReaction', anything)
    expect(runner).to have_received(:puts).with('Copilot review request failed: GitHub request failed.')
    expect(runner).to be_failed
  end

  it 'skips the review quietly when no token can request one' do
    environment.delete('COPILOT_GITHUB_TOKEN')
    runner = run_with

    expect(runner).not_to have_received(:mutate).with('requestReviewsByLogin', anything)
    expect(runner).to have_received(:puts).with(start_with('Copilot review: skipped'))
    expect(runner).not_to be_failed
  end

  it 'rejects a decision without the pull request fields' do
    decision.delete(:review)
    runner = run_with

    expect(runner).to be_failed
    expect(runner).not_to have_received(:mutate)
  end

  it 'skips drafts' do
    item['isDraft'] = true

    expect(run_with).to have_received(:puts).with('Skipped: pull request is a draft.')
  end

  it 'skips pull requests unless the policy enables them' do
    File.write('pr-triage.yml', YAML.dump(YAML.safe_load_file('triage.yml')))
    runner = run_with

    expect(runner).not_to have_received(:ask_copilot)
    expect(runner).to have_received(:puts).with('Skipped: pull request triage is not enabled in the policy.')
  end
end
