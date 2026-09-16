# frozen_string_literal: true

require_relative '../lib/assessment'

RSpec.describe 'Related issue assessment' do
  let(:environment) do
    { 'GITHUB_REPOSITORY' => 'owner/project', 'TRIAGE_NUMBER' => '123',
      'TRIAGE_KIND' => 'issue', 'TRIAGE_CONFIG' => 'triage.yml' }
  end
  let(:assessment) { IssueAssessment.new(environment) }
  let(:mode) { 'suggest' }
  let(:item) do
    { 'id' => 'current-id', 'title' => 'Remember the theme', 'body' => 'The theme resets after restarting.',
      'closed' => false, 'stateReason' => nil, 'authorAssociation' => 'NONE',
      'author' => { 'login' => 'reporter' }, 'comments' => { 'nodes' => [] } }
  end
  let(:candidate) do
    { 'id' => 'candidate-id', 'number' => 42, 'title' => 'Persist theme across restarts',
      'body' => 'The selected theme resets each time I restart.', 'closed' => false,
      'author' => { 'login' => 'another-reporter' }, 'comments' => { 'nodes' => [] } }
  end
  let(:catalog) { [{ 'number' => 42, 'title' => candidate['title'] }, { 'number' => 123, 'title' => item['title'] }] }
  let(:selection) { { 'labels' => [], 'reply' => nil, 'files' => [], 'related_issue' => 42 } }
  let(:comparison) do
    { 'relationship' => 'duplicate',
      'comment' => 'Both reports describe the selected theme resetting after a restart.' }
  end
  let(:prompts) { [] }
  let(:mutations) { [] }

  before do
    config = YAML.safe_load_file('triage.yml')
    mode ? config['duplicates'] = mode : config.delete('duplicates')
    File.write('triage.yml', YAML.dump(config))
    allow(assessment).to receive(:puts)
    allow(assessment).to receive(:ask_copilot) do |prompt|
      prompts << prompt
      JSON.generate(prompts.size == 1 ? selection : comparison)
    end
    allow(assessment).to receive(:github) do |endpoint, query:, variables:|
      expect(endpoint).to eq('graphql')
      if query.start_with?('mutation')
        mutations << [query, variables.fetch(:input)]
        {}
      else
        expect(variables).to include(owner: 'owner', name: 'project')
        record = if query.include?('issues(first:')
                   { 'issues' => { 'nodes' => catalog } }
                 elsif variables[:number] == 42
                   { 'issue' => candidate }
                 else
                   expect(variables[:number]).to eq(123)
                   { environment['TRIAGE_KIND'] => item, 'labels' => { 'nodes' => [] } }
                 end
        JSON.parse(JSON.generate({ 'data' => { 'repository' => record } }))
      end
    end
  end

  def operations
    mutations.map { |query, _input| query[/\{ (\w+)\(/, 1] }
  end

  def comment
    mutations.find { |_query, input| input.key?(:body) }&.last&.fetch(:body)
  end

  it 'lists open issues from the same repository, excludes itself, and compares full reports in a second call' do
    candidate['comments']['nodes'] << { 'body' => 'Also reproduced with a light theme.' }
    assessment.run

    expect(prompts.size).to eq(2)
    expect(prompts.first).to include('Open issues: {"42":"Persist theme across restarts"}')
    expect(prompts.last).to include(candidate['body'], 'Also reproduced with a light theme.')
    expect(assessment).to have_received(:github).with('graphql', query: include('states: OPEN', 'first: 100'),
                                                                 variables: { owner: 'owner', name: 'project' }).once
    expect(comment).to start_with('See also #42. Both reports')
    expect(operations).to eq(%w[addComment addReaction])
  end

  context 'without a duplicates setting' do
    let(:mode) { nil }

    it 'suggests links without closing' do
      assessment.run
      expect(comment).to start_with('See also #42.')
      expect(operations).not_to include('closeIssue')
    end
  end

  context 'with duplicate detection disabled' do
    let(:mode) { 'off' }

    it 'does not fetch other issues or spend a comparison call' do
      selection['related_issue'] = nil
      assessment.run
      expect(prompts.size).to eq(1)
      expect(assessment).not_to have_received(:github).with('graphql', query: include('issues(first:'),
                                                                       variables: anything)
    end
  end

  it 'bounds the title catalog even when titles are large' do
    catalog.replace((200..299).map { |number| { 'number' => number, 'title' => '界' * 500 } })
    selection['related_issue'] = nil
    assessment.run
    titles = JSON.parse(prompts.first[/Open issues: (.*)/, 1])
    expect(JSON.generate(titles).bytesize).to be <= 8000
    expect(titles.values.map(&:length).uniq).to eq([160])
    expect(titles.size).to be < 100
  end

  context 'with automatic closure enabled' do
    let(:mode) { 'close' }

    it 'comments then closes a newer issue with the native duplicate target, before marking completion' do
      assessment.run
      expect(comment).to start_with('Duplicate of #42.')
      expect(operations).to eq(%w[addComment closeIssue addReaction])
      expect(mutations[1].last).to eq(issueId: 'current-id', stateReason: 'DUPLICATE', duplicateIssueId: 'candidate-id')
    end

    it 'closes a duplicate discussion through the discussion API' do
      environment['TRIAGE_KIND'] = 'discussion'
      assessment.instance_variable_set(:@kind, 'discussion')
      assessment.run
      expect(operations).to eq(%w[addDiscussionComment closeDiscussion addReaction])
      expect(mutations[1].last).to eq(discussionId: 'current-id', reason: 'DUPLICATE')
    end

    it 'leaves related reports open and explains their difference' do
      comparison.replace(
        'relationship' => 'related',
        'comment' => ['Both concern theme settings, but this report concerns restarting',
                      'rather than switching themes.'].join(' ')
      )
      assessment.run
      expect(comment).to start_with('See also #42.')
      expect(operations).to eq(%w[addComment addReaction])
    end

    it 'does not close an older issue in favor of a newer one' do
      assessment.instance_variable_set(:@number, 12)
      allow(assessment).to receive(:read_report).and_return([item, []])
      assessment.run
      expect(comment).to start_with('See also #42.')
      expect(operations).not_to include('closeIssue')
    end

    it 'does not close a reopened issue' do
      item['stateReason'] = 'REOPENED'
      assessment.run
      expect(comment).to start_with('See also #42.')
      expect(operations).not_to include('closeIssue')
    end

    it 'does not close a maintainer-authored report' do
      item['authorAssociation'] = 'OWNER'
      assessment.run
      expect(comment).to start_with('See also #42.')
      expect(operations).not_to include('closeIssue')
    end

    it 'does not close a report with recent maintainer participation' do
      item['comments']['nodes'] = [
        { 'body' => 'Keeping this open.', 'authorAssociation' => 'COLLABORATOR' },
        { 'body' => 'Thank you.', 'authorAssociation' => 'NONE' }
      ]
      assessment.run
      expect(comment).to start_with('See also #42.')
      expect(operations).not_to include('closeIssue')
    end

    it 'does not close a report again after a previous bot duplicate comment' do
      item['comments']['nodes'] << { 'body' => 'Duplicate of #42.', 'author' => { '__typename' => 'Bot' } }
      assessment.run
      expect(operations).not_to include('closeIssue')
    end

    it 'does not mark the assessment complete when closure fails' do
      allow(assessment).to receive(:github).with('graphql', query: include('closeIssue(input:'), variables: anything)
                                           .and_raise('GitHub request failed')
      expect { assessment.run }.to raise_error('GitHub request failed')
      expect(comment).to start_with('Duplicate of #42.')
      expect(operations).not_to include('addReaction')
    end

    it 'previews a closure without making any GitHub mutations' do
      environment['TRIAGE_DRY_RUN'] = 'true'
      assessment.run
      expect(mutations).to be_empty
      expect(assessment).to have_received(:puts).with(include('"close":true'))
    end
  end

  it 'can add a useful link after an older bot answer during a manual assessment' do
    item['comments']['nodes'] << { 'body' => 'Which version?', 'author' => { '__typename' => 'Bot' } }
    assessment.run
    expect(prompts.size).to eq(2)
    expect(comment).to start_with('See also #42.')
  end

  it 'does not interrupt a maintainer who commented last' do
    item['comments']['nodes'] << { 'body' => 'Keeping this separate.', 'authorAssociation' => 'OWNER' }
    assessment.run
    expect(prompts.size).to eq(1)
    expect(comment).to be_nil
  end

  it 'stays silent when the full reports establish no useful relationship' do
    comparison.replace('relationship' => 'none', 'comment' => nil)
    assessment.run
    expect(operations).to eq(['addReaction'])
  end

  [123, 500, '42', false, 'other/repo#42'].each do |invalid|
    it "rejects an unlisted or invalid candidate #{invalid.inspect} before fetching its body" do
      selection['related_issue'] = invalid
      assessment.run
      expect(prompts.size).to eq(1)
      expect(mutations).to be_empty
    end
  end

  [
    { 'reply' => 'version' }, { 'files' => ['docs/tools.md'] },
    { 'comment' => 'Another answer.' }, { 'close' => true }
  ].each do |extra|
    it "rejects a second reply route or model-controlled closure #{extra.inspect}" do
      selection.merge!(extra)
      assessment.run
      expect(prompts.size).to eq(1)
      expect(mutations).to be_empty
    end
  end

  [
    { 'relationship' => 'duplicate', 'comment' => nil },
    { 'relationship' => 'none', 'comment' => 'Still close it.' },
    { 'relationship' => 'duplicate', 'comment' => 'See #999.' },
    { 'relationship' => 'duplicate', 'comment' => 'See https://example.com.' },
    { 'relationship' => 'duplicate', 'comment' => 'One. Two. Three.' },
    { 'relationship' => 'duplicate', 'comment' => 'Yes.', 'close' => true }
  ].each do |invalid|
    it "rejects an invalid comparison #{invalid.inspect} without publishing" do
      comparison.replace(invalid)
      assessment.run
      expect(mutations).to be_empty
    end
  end

  it 'skips a candidate that has closed since the title catalog was read' do
    candidate['closed'] = true
    assessment.run
    expect(prompts.size).to eq(1)
    expect(mutations).to be_empty
  end

  it 'skips a candidate that is no longer accessible' do
    allow(assessment).to receive(:github).with('graphql', query: anything,
                                                          variables: { owner: 'owner', name: 'project', number: 42 })
                                         .and_return({ 'data' => { 'repository' => { 'issue' => nil } } })
    assessment.run
    expect(prompts.size).to eq(1)
    expect(mutations).to be_empty
  end

  it 'rechecks the candidate after inference and skips if it changed' do
    allow(assessment).to receive(:ask_copilot).and_wrap_original do |_method, prompt|
      prompts << prompt
      candidate['body'] = 'Edited during comparison.' if prompts.size == 2
      JSON.generate(prompts.size == 1 ? selection : comparison)
    end
    assessment.run
    expect(mutations).to be_empty
    expect(assessment).to have_received(:puts).with(start_with('Skipped: related issue changed'))
  end

  it 'rechecks the current report after inference and skips if it changed' do
    allow(assessment).to receive(:ask_copilot) do |prompt|
      prompts << prompt
      item['body'] = 'Actually these are different.' if prompts.size == 2
      JSON.generate(prompts.size == 1 ? selection : comparison)
    end
    assessment.run
    expect(mutations).to be_empty
    expect(assessment).to have_received(:puts).with(start_with('Skipped: the report changed'))
  end

  it 'applies a cached preview with no new model calls while still rechecking both reports' do
    environment['TRIAGE_CACHE_DIR'] = '.cache'
    environment['TRIAGE_DRY_RUN'] = 'true'
    assessment.run
    prompts.clear
    environment['TRIAGE_DRY_RUN'] = 'false'
    second = IssueAssessment.new(environment)
    allow(second).to receive(:github) { |*args, **kwargs| assessment.send(:github, *args, **kwargs) }
    allow(second).to receive(:puts)
    expect(second).not_to receive(:ask_copilot)
    second.run
    expect(prompts).to be_empty
    expect(comment).to include('cached response; 0 new model tokens')
    expect(assessment).to have_received(:github).with(
      'graphql', query: anything, variables: { owner: 'owner', name: 'project', number: 42 }
    ).exactly(4).times
  end
end
