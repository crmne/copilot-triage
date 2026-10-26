# frozen_string_literal: true

require_relative '../lib/assessment'

RSpec.describe 'Report context' do
  let(:config) { YAML.safe_load_file('triage.yml') }
  let(:environment) do
    { 'GITHUB_REPOSITORY' => 'crmne/example', 'TRIAGE_NUMBER' => '1', 'TRIAGE_CONFIG' => 'triage.yml' }
  end
  let(:assessment) { IssueAssessment.new(environment) }
  let(:item) do
    { 'id' => 'report-id', 'title' => 'Follow system does not update', 'body' => 'A complete report.',
      'closed' => false, 'author' => { '__typename' => 'User', 'login' => 'reporter' },
      'comments' => { 'nodes' => [] } }
  end
  let(:decision) { JSON.generate(labels: [], reply: nil, sources: []) }

  before do
    File.write('triage.yml', config.to_yaml)
    allow(assessment).to receive_messages(read_report: [item, []], ask_copilot: decision)
    allow(assessment).to receive(:mutate)
    allow(assessment).to receive(:puts)
  end

  it 'compacts escaped NUL padding while preserving the surrounding report and log messages' do
    item['body'] = "Fedora Silverblue, GNOME, Flatpak.\n#{'\\00' * 6000}\nA meaningful error after the padding."
    original = Marshal.load(Marshal.dump(item))

    assessment.run

    expect(assessment).to have_received(:ask_copilot).with(include('Fedora Silverblue', '[6000 repeated NUL bytes]',
                                                                   'A meaningful error after the padding.'))
    expect(item).to eq(original)
    expect(assessment).to have_received(:mutate).with('addReaction', anything)
  end

  it 'compacts actual NUL bytes in a comment' do
    item['comments']['nodes'] << { 'body' => "Before #{"\x00" * 6000} after", 'author' => { 'login' => 'reporter' } }

    assessment.run

    expect(assessment).to have_received(:ask_copilot).with(include('Before', '[6000 repeated NUL bytes]', 'after'))
  end

  it 'preserves short NUL sequences that could be a reproduction' do
    item['body'] = "The input was #{'\\00' * 3}."

    assessment.run

    expect(assessment).to have_received(:ask_copilot).with(include(JSON.generate(item['body'])))
  end

  it 'separates the triggering comment from the original report and earlier conversation' do
    earlier = { 'body' => 'Which OS?', 'author' => { 'login' => 'github-actions' } }
    latest = { 'body' => 'Fedora 43', 'author' => { 'login' => 'reporter' } }
    item['comments']['nodes'] = [earlier, latest]
    original = Marshal.load(Marshal.dump(item))

    context = JSON.parse(assessment.send(:report_context, item))

    expect(context['latest_comment']).to eq(latest)
    expect(context['earlier_comments']).to eq([earlier])
    expect(context['body']).to eq(item['body'])
    expect(item).to eq(original)
  end

  it 'identifies follow-up assessments by event metadata, not comment wording' do
    environment['GITHUB_EVENT_NAME'] = 'issue_comment'
    assessment.instance_variable_set(:@state, ConversationState.new(nil, 'test'))

    prompt = assessment.send(:build_prompt, item, [])

    expect(prompt).to include('follow-up: assess the latest_comment, not the original report again')
  end

  it 'tells the agent how far the default branch is ahead of the latest stable release', :releases do
    assessment.instance_variable_set(:@state, ConversationState.new(nil, 'test'))
    allow(assessment.send(:evidence_tools)).to receive(:api) do |endpoint|
      if endpoint.include?('/releases?')
        [{ 'tag_name' => 'v0.19.0', 'prerelease' => false, 'published_at' => '2026-10-03T18:46:30Z' }]
      else
        { 'ahead_by' => 183, 'commits' => [] }
      end
    end

    prompt = assessment.send(:build_prompt, item, [])

    expect(prompt).to include('Releases: repository files show the default branch, 183 commits after ' \
                              'the latest stable release, v0.19.0 (2026-10-03).')
  end

  it 'tells the agent only in the release pass that the issue is checked against a new release' do
    assessment.instance_variable_set(:@state, ConversationState.new(nil, 'test'))
    expect(assessment.send(:build_prompt, item, [])).not_to include('Release check:')

    environment.merge!('TRIAGE_RELEASE' => 'v0.20.1', 'TRIAGE_RELEASE_PULLS' => '370 371')
    prompt = assessment.send(:build_prompt, item, [])

    expect(prompt).to include('Release check: this run checks the report against v0.20.1, just published, ' \
                              'because pull requests #370, #371 in it reference this issue.')
    expect(prompt).to include('every pull request it lists is now merged and released, ask in one sentence')
  end

  it "lists this repository's open and recently merged pull requests that reference the issue" do
    pull = lambda do |number, state, merged_at: nil, repository: 'crmne/example'|
      { 'number' => number, 'title' => "Fix #{number}", 'state' => state, 'merged' => !merged_at.nil?,
        'mergedAt' => merged_at, 'author' => { 'login' => 'contributor' },
        'repository' => { 'nameWithOwner' => repository } }
    end
    item['closedByPullRequestsReferences'] = { 'nodes' => [pull.call(31, 'OPEN')] }
    item['timelineItems'] = { 'nodes' => [
      { 'source' => pull.call(31, 'OPEN') }, { 'source' => { 'number' => 7, 'title' => 'An issue' } },
      { 'source' => pull.call(40, 'MERGED', merged_at: (Time.now - 86_400).utc.iso8601) },
      { 'source' => pull.call(41, 'MERGED', merged_at: '2020-01-01T00:00:00Z') },
      { 'source' => pull.call(42, 'CLOSED') }, { 'source' => pull.call(43, 'OPEN', repository: 'other/fork') }, {}
    ] }

    context = JSON.parse(assessment.send(:report_context, item))

    expect(context['pull_requests']).to eq([
                                             { 'number' => 31, 'title' => 'Fix 31', 'state' => 'OPEN',
                                               'merged' => false, 'author' => 'contributor' },
                                             { 'number' => 40, 'title' => 'Fix 40', 'state' => 'MERGED',
                                               'merged' => true, 'author' => 'contributor' }
                                           ])
    expect(assessment.send(:report_facts, item)['pull_requests']).to eq([31, 40])
    expect(assessment.send(:linked_pull_request_fields)).to include('closedByPullRequestsReferences(first: 10',
                                                                    'CROSS_REFERENCED_EVENT')
  end

  it 'lists no pull requests when none reference the issue' do
    expect(JSON.parse(assessment.send(:report_context, item))).not_to have_key('pull_requests')
  end

  it 'leaves the release baseline out when GitHub cannot be read', :releases do
    assessment.instance_variable_set(:@state, ConversationState.new(nil, 'test'))
    allow(assessment.send(:evidence_tools)).to receive(:api).and_raise(IOError, 'GitHub read failed')

    expect(assessment.send(:build_prompt, item, [])).not_to include('Releases:')
  end

  it 'gives the agent a long conversation in full' do
    item['comments']['nodes'] = (1..40).map do |number|
      { 'id' => "comment-#{number}", 'body' => "Update #{number}: #{'details ' * 100}",
        'author' => { 'login' => 'reporter' }, 'authorAssociation' => 'NONE' }
    end

    assessment.run

    expect(assessment).to have_received(:ask_copilot).with(include('Update 1:', 'Update 39:', 'Update 40:'))
    expect(assessment).not_to have_received(:ask_copilot).with(include('bytes omitted'))
  end

  it 'keeps the beginning and end of a huge pasted log without repeated padding' do
    item['body'] = "Started.\n#{'Important log data. ' * 2000}Crashed here."

    assessment.run

    expect(assessment).to have_received(:ask_copilot).with(include('Started.', 'bytes omitted', 'Crashed here.'))
  end

  it 'keeps the most recent recovered history within its budget' do
    history = (1..60).map do |number|
      { 'id' => "old-#{number}", 'body' => "Old comment #{number}. #{'x' * 900}", 'author' => { 'login' => 'reporter' },
        'authorAssociation' => 'NONE' }
    end
    assessment.instance_variable_set(:@recovered_comments, history)

    recovered = assessment.send(:recovered_context)
    expect(JSON.generate(recovered).bytesize).to be <= 40_000
    expect(recovered.last['body']).to start_with('Old comment 60.')
    expect(recovered.first['body']).not_to start_with('Old comment 1.')
  end

  it 'posts a necessary clarification without a recap with a single model call' do
    comment = 'Does restarting the app pick up the system theme?'
    allow(assessment).to receive(:ask_copilot).and_return(JSON.generate(labels: [], reply: nil, sources: [],
                                                                        comment: comment))

    assessment.run

    expect(assessment).to have_received(:ask_copilot).once
    expect(assessment).to have_received(:mutate).with('addComment', subjectId: 'report-id',
                                                                    body: start_with("#{comment}\n\n"))
  end

  let(:long_report) { "On Arch Linux the app idles at 90% CPU after I connect my account. #{'More details. ' * 200}" }

  it 'allows one useful recap on a newly opened issue' do
    environment.merge!('GITHUB_EVENT_NAME' => 'issues', 'GITHUB_EVENT_PATH' => 'event.json')
    File.write('event.json', JSON.generate(action: 'opened'))
    item['body'] = long_report
    comment = 'On Arch Linux, connected sessions use 90% CPU while idle; a patched build uses 0-5% on the same profile.'
    allow(assessment).to receive(:ask_copilot).and_return(
      JSON.generate(labels: [], reply: nil, sources: [], comment: comment)
    )

    assessment.run

    expect(assessment).to have_received(:ask_copilot).with(include('Initial issue recap permitted: true'))
    expect(assessment).to have_received(:mutate).with('addComment', subjectId: 'report-id',
                                                                    body: start_with(comment))
  end

  context 'with a recap' do
    before do
      environment.merge!('GITHUB_EVENT_NAME' => 'issues', 'GITHUB_EVENT_PATH' => 'event.json')
      File.write('event.json', JSON.generate(action: 'opened'))
      item['body'] = long_report
    end

    def recap(comment, recap: true)
      allow(assessment).to receive(:ask_copilot).and_return(
        JSON.generate(labels: [], reply: nil, sources: [], comment: comment, recap: recap)
      )
      assessment.run
    end

    it 'labels it' do
      recap('Connected sessions idle at 90% CPU on Arch Linux.')

      expect(assessment).to have_received(:mutate).with(
        'addComment', subjectId: 'report-id', body: start_with('Recap: Connected sessions idle at 90% CPU')
      )
    end

    it 'keeps one that says what the reporter asks the maintainer' do
      recap('The reporter offers three ways forward for the maintainer to choose between.')

      expect(assessment).to have_received(:mutate).with('addComment', subjectId: 'report-id',
                                                                      body: start_with('Recap: The reporter offers'))
    end

    it 'still drops one that grades the report' do
      recap('Confirmed bug: connected sessions idle at 90% CPU.')

      expect(assessment).not_to have_received(:mutate).with('addComment', anything)
    end

    it 'labels no other comment' do
      recap('Does signing out bring the CPU back down?', recap: false)

      expect(assessment).to have_received(:mutate).with('addComment', subjectId: 'report-id',
                                                                      body: start_with('Does signing out'))
    end
  end

  it 'refuses a recap flag when no recap is permitted' do
    allow(assessment).to receive(:ask_copilot).and_return(
      JSON.generate(labels: [], reply: nil, sources: [], comment: 'Short recap.', recap: true)
    )

    assessment.run

    expect(assessment).not_to have_received(:mutate).with('addComment', anything)
  end

  it 'allows a recap of a long report written in a template' do
    environment.merge!('GITHUB_EVENT_NAME' => 'issues', 'GITHUB_EVENT_PATH' => 'event.json')
    File.write('event.json', JSON.generate(action: 'opened'))
    item['body'] = "### What happened?\n\n#{'More details. ' * 60}\nExpected: idle.\nActual: 90% CPU."

    assessment.run

    expect(assessment).to have_received(:ask_copilot).with(include('Initial issue recap permitted: true'))
  end

  {
    'a short report' => 'The app idles at 90% CPU after I connect my account.',
    'a long log with a short description' => "The app idles at 90% CPU.\n```text\n#{"WARN cpu busy\n" * 400}```"
  }.each do |description, body|
    it "permits no recap of #{description}" do
      environment.merge!('GITHUB_EVENT_NAME' => 'issues', 'GITHUB_EVENT_PATH' => 'event.json')
      File.write('event.json', JSON.generate(action: 'opened'))
      item['body'] = body

      assessment.run

      expect(assessment).to have_received(:ask_copilot).with(include('Initial issue recap permitted: false'))
    end
  end

  it 'does not treat reopening an issue as permission for another recap' do
    environment.merge!('GITHUB_EVENT_NAME' => 'issues', 'GITHUB_EVENT_PATH' => 'event.json')
    File.write('event.json', JSON.generate(action: 'reopened'))
    allow(assessment).to receive(:ask_copilot).and_return(
      decision
    )

    assessment.run

    expect(assessment).to have_received(:ask_copilot).with(include('Initial issue recap permitted: false'))
    expect(assessment).not_to have_received(:mutate).with('addComment', anything)
  end

  it 'remembers that the initial issue assessment has already happened' do
    environment.merge!('GITHUB_EVENT_NAME' => 'issues', 'GITHUB_EVENT_PATH' => 'event.json',
                       'TRIAGE_STATE_DIR' => 'state')
    File.write('event.json', JSON.generate(action: 'opened'))
    item['body'] = long_report
    comment = 'On Arch Linux, connected sessions use 90% CPU while idle.'
    allow(assessment).to receive(:ask_copilot).and_return(
      JSON.generate(labels: [], reply: nil, sources: [], comment: comment)
    )

    assessment.run
    assessment.run

    expect(assessment).to have_received(:ask_copilot).once
    expect(assessment).to have_received(:mutate).with('addComment', anything).once
    expect(JSON.parse(File.read(Dir['state/*.json'].first))['initial_assessed']).to be(true)
  end

  it 'does not turn a silent initial assessment into a later recap' do
    environment.merge!('GITHUB_EVENT_NAME' => 'issues', 'GITHUB_EVENT_PATH' => 'event.json',
                       'TRIAGE_STATE_DIR' => 'state')
    File.write('event.json', JSON.generate(action: 'opened'))
    assessment.run
    item['body'] = 'An edited report changes the event fingerprint.'
    allow(assessment).to receive(:ask_copilot).and_return(
      decision
    )

    assessment.run

    expect(assessment).to have_received(:ask_copilot).twice
    expect(assessment).not_to have_received(:mutate).with('addComment', anything)
  end

  it 'puts conversational judgment in the system prompt, not keyword filters' do
    prompt = assessment.send(:system_prompt)
    expect(prompt).to include('Do not recap every comment', 'Use judgment', 'check the docs',
                              'submit_decision', 'untrusted evidence')
  end

  it 'previews an initial assessment without publishing it' do
    environment['TRIAGE_DRY_RUN'] = 'true'
    allow(assessment).to receive(:ask_copilot).and_return(
      JSON.generate(labels: [], reply: nil, sources: [], comment: 'Does restarting the app pick up the theme?')
    )

    assessment.run

    expect(assessment).to have_received(:ask_copilot).once
    expect(assessment).not_to have_received(:mutate)
  end

  it 'suppresses a generated assessment after a maintainer has answered' do
    item['comments']['nodes'] << { 'body' => 'I found the cause.', 'author' => { 'login' => 'owner' },
                                   'authorAssociation' => 'OWNER' }
    allow(assessment).to receive(:ask_copilot).and_return(
      JSON.generate(labels: [], reply: nil, sources: [], comment: 'Does restarting the app pick up the theme?')
    )

    assessment.run

    expect(assessment).not_to have_received(:mutate).with('addComment', anything)
  end

  [false, ['A reply'], 'Read https://example.com', 'See [[lib/ruby_llm/tool.rb]].'].each do |comment|
    it "rejects an invalid report-based assessment: #{comment.inspect}" do
      allow(assessment).to receive(:ask_copilot).and_return(JSON.generate(labels: [], reply: nil, sources: [],
                                                                          comment: comment))

      assessment.run

      expect(assessment).not_to have_received(:mutate)
    end
  end

  it 'rejects competing reply routes' do
    allow(assessment).to receive(:ask_copilot).and_return(JSON.generate(labels: [], reply: 'version', sources: [],
                                                                        comment: 'Does restarting pick up the theme?'))

    assessment.run

    expect(assessment).not_to have_received(:mutate)
    expect(assessment).to have_received(:puts).with(
      start_with('Failed: invalid assessment (both a comment and a configured reply: ArgumentError in validate at')
    )
  end

  context 'with a configured reporting bot' do
    let(:config) { super().merge('report_bots' => ['honeybadger[bot]']) }

    %w[honeybadger honeybadger[bot]].each do |login|
      it "assesses a report from the verified #{login} bot" do
        item['author'] = { '__typename' => 'Bot', 'login' => login }

        assessment.run

        expect(assessment).to have_received(:ask_copilot).once
        expect(assessment).to have_received(:mutate).with('addReaction', anything)
      end
    end

    it 'does not allow other bots even if their report mentions Honeybadger' do
      item['author'] = { '__typename' => 'Bot', 'login' => 'github-actions' }
      item['body'] = 'Created by honeybadger[bot]'

      assessment.run

      expect(assessment).not_to have_received(:ask_copilot)
      expect(assessment).not_to have_received(:mutate)
    end

    it 'continues to skip bot comments, including the allowed reporting bot' do
      item['author'] = { '__typename' => 'Bot', 'login' => 'honeybadger' }
      environment.merge!('GITHUB_EVENT_NAME' => 'issue_comment', 'GITHUB_EVENT_PATH' => 'event.json')
      File.write('event.json', JSON.generate(action: 'created', issue: { number: 1, state: 'open' },
                                             sender: { type: 'Bot', login: 'honeybadger[bot]' },
                                             comment: { user: { type: 'Bot', login: 'honeybadger[bot]' } }))

      assessment.run

      expect(assessment).not_to have_received(:read_report)
      expect(assessment).not_to have_received(:ask_copilot)
    end
  end

  it 'skips reporting bots unless the repository explicitly allows them' do
    item['author'] = { '__typename' => 'Bot', 'login' => 'honeybadger' }

    assessment.run

    expect(assessment).not_to have_received(:ask_copilot)
  end
end
