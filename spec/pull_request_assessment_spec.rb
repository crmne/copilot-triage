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

  it "judges the pull request itself when CodeRabbit's review limit ran out" do
    notice = { 'id' => 'notice-id', 'author' => { '__typename' => 'Bot', 'login' => 'coderabbitai' },
               'authorAssociation' => 'NONE',
               'body' => "> [!WARNING]\n> ## Review limit reached\n>\n> You've used all free OSS reviews for " \
                         "now.\n>\n> **Next included review available in 2 minutes.**" }
    item['comments']['nodes'] << notice
    File.write('event.json', JSON.generate('action' => 'created', 'issue' => { 'pull_request' => {} },
                                           'comment' => { 'node_id' => 'notice-id', 'body' => notice['body'],
                                                          'user' => { 'login' => 'coderabbitai[bot]' } }))
    environment.merge!('GITHUB_EVENT_NAME' => 'issue_comment', 'GITHUB_EVENT_PATH' => 'event.json')

    runner = run_with

    expect(runner).to have_received(:ask_copilot) do |prompt|
      expect(prompt).to include('review update: judge copilot_review and other_reviews',
                                '"coderabbitai":{"reviewed":false,' \
                                '"unavailable":"review limit reached; next review in 2 minutes"}')
    end
  end

  it "keeps CodeRabbit's review when it reviewed the latest commit despite an older notice" do
    item['comments']['nodes'] << { 'author' => { 'login' => 'coderabbitai' }, 'body' => '> ## Reviews paused' }
    item['findings'] = { 'nodes' => [{ 'author' => { 'login' => 'coderabbitai' }, 'state' => 'APPROVED',
                                       'body' => '', 'commit' => { 'oid' => 'a' * 40 }, 'comments' => {} }] }

    expect(BotReviews.unavailable(item)).to eq({})
  end

  context 'when Copilot reviews only private repositories' do
    let(:policy) { { 'reviews' => 'private' } }

    it 'requests a review in a private repository but not in a public one' do
      File.write('event.json', JSON.generate('repository' => { 'private' => true }))
      environment.merge!('GITHUB_EVENT_NAME' => 'workflow_dispatch', 'GITHUB_EVENT_PATH' => 'event.json')
      expect(run_with).to have_received(:mutate).with('requestReviewsByLogin', anything)

      File.write('event.json', JSON.generate('repository' => { 'private' => false }))
      FileUtils.rm_rf('state')
      expect(run_with).not_to have_received(:mutate).with('requestReviewsByLogin', anything)
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

  it 'gives the agent facts that contribution rules often govern' do
    item['files']['nodes'] += [
      { 'path' => 'docs/assets/review/after.png', 'additions' => 0, 'deletions' => 0, 'changeType' => 'ADDED' },
      { 'path' => 'docs/assets/logo.png', 'additions' => 0, 'deletions' => 0, 'changeType' => 'MODIFIED' },
      { 'path' => 'Cargo.toml', 'additions' => 2, 'deletions' => 0, 'changeType' => 'MODIFIED' }
    ]
    runner = described_class.new(environment)
    allow(runner).to receive_messages(read_report: [item, labels])
    allow(runner).to receive(:ask_copilot) { JSON.generate(decision) }
    allow(runner).to receive(:mutate)
    allow(runner).to receive(:puts)
    patch = "@@ -10,2 +10,4 @@\n [dependencies]\n+serde = \"1\"\n" \
            "+egui = { git = \"https://github.com/someone/egui\", branch = \"fix\" }\n"
    allow(runner).to receive(:github).with('repos/crmne/ruby_llm/pulls/77/files?per_page=100')
                                     .and_return([{ 'filename' => 'Cargo.toml', 'patch' => patch }])
    runner.run

    expect(runner).to have_received(:ask_copilot).with(include(
                                                         '"policy_facts":{"added_binary_files":' \
                                                         '["docs/assets/review/after.png"],' \
                                                         '"changed_dependency_manifests":["Cargo.toml"],' \
                                                         '"source_dependency_lines":["Cargo.toml: egui = { git = ' \
                                                         '\\"https://github.com/someone/egui\\", branch = ' \
                                                         '\\"fix\\" }"]}'
                                                       ))
    expect(runner.send(:system_prompt)).to include('policy_facts lists')
  end

  it 'lists the template checkboxes the description leaves unticked' do
    item['body'] = "## Checklist\n\n- [x] I ran the tests\n- [ ] I understand and take responsibility for " \
                   "every submitted line\n* [ ]  Screenshots attached\n\nSee [docs](https://example.com)."
    runner = run_with

    expect(runner).to have_received(:ask_copilot).with(include(
                                                         '"unchecked_boxes":["I understand and take ' \
                                                         'responsibility for every submitted line",' \
                                                         '"Screenshots attached"]'
                                                       ))
  end

  context 'with visual paths' do
    let(:policy) { { 'visual_paths' => ['src/ui/**'] } }

    it 'counts review media when a pull request changes the visible interface' do
      item['files']['nodes'] << { 'path' => 'src/ui/sidebar.rs', 'additions' => 4, 'deletions' => 1,
                                  'changeType' => 'MODIFIED' }
      runner = run_with

      expect(runner).to have_received(:ask_copilot).with(include(
                                                           '"policy_facts":{"visual_files_changed":' \
                                                           '["src/ui/sidebar.rs"],"review_media":0}'
                                                         ))
    end

    it 'counts attachments in the description and the author\'s comments' do
      item['files']['nodes'] << { 'path' => 'src/ui/sidebar.rs', 'additions' => 4, 'deletions' => 1,
                                  'changeType' => 'MODIFIED' }
      item['body'] = "Before and after:\n\n![before](https://github.com/user-attachments/assets/1)"
      item['comments']['nodes'] << { 'author' => item['author'], 'authorAssociation' => 'CONTRIBUTOR',
                                     'body' => '<img src="https://example.com/after.png">' }
      runner = run_with

      expect(runner).to have_received(:ask_copilot).with(include('"review_media":2'))
    end
  end

  it 'leaves policy facts empty for an ordinary change' do
    runner = run_with

    expect(runner).to have_received(:ask_copilot).with(include('"policy_facts":{}'))
  end

  context 'with facts read from GitHub', :github_facts do
    let(:checks) { { 'contexts' => { 'nodes' => [{ 'name' => 'test', 'conclusion' => 'SUCCESS' }] } } }
    let(:open_pulls) { [] }
    let(:commits) { ['c' * 40, 'a' * 40] }
    let(:base_files) { [] }
    let(:runner) do
      described_class.new(environment).tap do |runner|
        allow(runner).to receive(:github) do |endpoint, query: '', **|
          if endpoint.include?('/compare/') then { 'files' => base_files }
          elsif query.include?('statusCheckRollup')
            commit = { 'commit' => { 'statusCheckRollup' => checks } }
            { 'data' => { 'node' => { 'commits' => { 'nodes' => [commit] } } } }
          else
            { 'data' => { 'repository' => {
              'defaultBranchRef' => { 'name' => 'main' },
              'pullRequest' => { 'commits' => { 'nodes' => commits.map { |oid| { 'commit' => { 'oid' => oid } } } } },
              'pullRequests' => { 'nodes' => open_pulls }
            } } }
          end
        end
      end
    end

    def facts
      runner.send(:policy_facts, item)
    end

    def open_pull(number, head: "branch-#{number}", base: 'main', oid: number.to_s * 40, paths: [])
      { 'number' => number, 'isCrossRepository' => false, 'headRefName' => head, 'baseRefName' => base,
        'headRefOid' => oid, 'files' => { 'nodes' => paths.map { |path| { 'path' => path } } } }
    end

    before { item.merge!('baseRefName' => 'main', 'mergeable' => 'MERGEABLE') }

    it 'says nothing about a mergeable pull request with passing checks and no neighbours' do
      expect(facts).to eq({})
    end

    it 'names the files the base branch also changed when the pull request conflicts' do
      item['mergeable'] = 'CONFLICTING'
      base_files.push({ 'filename' => 'README.md' }, { 'filename' => 'lib/stream.rb',
                                                       'previous_filename' => 'lib/ruby_llm/stream.rb' })

      expect(facts['merge_conflict']).to eq('base_branch' => 'main',
                                            'files_changed_on_both' => ['lib/ruby_llm/stream.rb'])
      expect(runner).to have_received(:github).with("repos/crmne/ruby_llm/compare/#{'a' * 40}...main")
    end

    it 'still reports a conflict when GitHub cannot list the changed files' do
      item['mergeable'] = 'CONFLICTING'
      allow(runner).to receive(:github).with(include('/compare/')).and_raise('GitHub request failed')

      expect(facts['merge_conflict']).to eq('base_branch' => 'main')
    end

    it 'names failing checks, leaving out cancelled runs and triage itself' do
      checks['contexts']['nodes'] += [{ 'name' => 'build', 'conclusion' => 'FAILURE' },
                                      { 'name' => 'lint', 'conclusion' => 'CANCELLED' },
                                      { 'name' => 'assess', 'conclusion' => 'FAILURE' },
                                      { 'context' => 'ci/legacy', 'state' => 'ERROR' }]

      expect(facts).to eq('failing_checks' => %w[build ci/legacy])
    end

    it 'says when no check ran on the head commit, and nothing when checks cannot be read' do
      checks['contexts']['nodes'] = [{ 'name' => 'assess', 'conclusion' => 'SUCCESS' }]
      expect(facts).to eq('no_checks_ran' => true)

      allow(runner).to receive(:github).with('graphql', hash_including(query: include('statusCheckRollup')))
                                       .and_raise('GitHub request failed')
      expect(facts).to eq({})
    end

    it 'finds the stack under the pull request, bottom first, and other pull requests on its files' do
      item['baseRefName'] = 'branch-30'
      open_pulls.push(open_pull(30, base: 'branch-29'), open_pull(29),
                      open_pull(32, oid: 'c' * 40, paths: ['lib/ruby_llm/stream.rb']),
                      open_pull(40, paths: ['lib/ruby_llm/stream.rb', 'Gemfile.lock']),
                      open_pull(41, paths: ['README.md']), open_pull(77, paths: ['lib/ruby_llm/stream.rb']))

      expect(facts).to eq('stacked_on' => [29, 30, 32],
                          'overlapping_pull_requests' => [{ 'number' => 40,
                                                            'shared_files' => ['lib/ruby_llm/stream.rb'] }])
    end

    it 'takes no branch of a fork for a stack' do
      fork = open_pull(50, head: 'main').merge('isCrossRepository' => true)
      item['baseRefName'] = 'main'
      open_pulls.push(fork, open_pull(51, head: 'release', base: 'main'))

      expect(facts).to eq({})
    end

    it 'leaves out what it cannot read about other pull requests' do
      allow(runner).to receive(:github).with('graphql', hash_including(query: include('pullRequests(')))
                                       .and_raise('GitHub request failed')

      expect(facts).to eq({})
    end
  end

  it 'points out regenerated translation catalogs and lockfiles no manifest explains' do
    item['files']['nodes'] += %w[po/de.po po/app.pot Cargo.lock crates/core/Gemfile.lock Gemfile].map do |path|
      { 'path' => path, 'additions' => 1, 'deletions' => 1, 'changeType' => 'MODIFIED' }
    end
    runner = described_class.new(environment)
    allow(runner).to receive(:github).and_return([])

    expect(runner.send(:policy_facts, item)).to eq(
      'changed_dependency_manifests' => ['Gemfile'], 'translation_catalogs' => %w[po/de.po po/app.pot],
      'unrelated_lockfiles' => ['Cargo.lock']
    )
    item['files']['nodes'] = item['files']['nodes'].last(5).first(2)
    expect(runner.send(:policy_facts, item)).to eq({})
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
