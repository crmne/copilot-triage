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
  let(:decision) { JSON.generate(labels: [], reply: nil, files: []) }

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

  it 'keeps the input budget for large reports without repeated padding' do
    item['body'] = 'Important log data. ' * 2000

    assessment.run

    expect(assessment).not_to have_received(:ask_copilot)
    expect(assessment).not_to have_received(:mutate)
  end

  it 'uses compacted context for the technical answer too' do
    item['body'] = "Before #{'\\00' * 6000} after"
    selection = JSON.generate(labels: [], reply: nil, files: ['lib/ruby_llm/tool.rb'])
    allow(assessment).to receive(:ask_copilot).and_return(selection, JSON.generate(comment: nil, sources: []))

    assessment.run

    expect(assessment).to have_received(:ask_copilot).with(include('[6000 repeated NUL bytes]')).twice
  end

  it 'posts a necessary clarification without a recap with a single model call' do
    comment = 'Does restarting the app pick up the system theme?'
    allow(assessment).to receive(:ask_copilot).and_return(JSON.generate(labels: [], reply: nil, files: [],
                                                                        comment: comment))

    assessment.run

    expect(assessment).to have_received(:ask_copilot).once
    expect(assessment).to have_received(:mutate).with('addComment', subjectId: 'report-id',
                                                                    body: start_with("#{comment}\n\n"))
  end

  it 'allows one useful recap on a newly opened issue' do
    environment.merge!('GITHUB_EVENT_NAME' => 'issues', 'GITHUB_EVENT_PATH' => 'event.json')
    File.write('event.json', JSON.generate(action: 'opened'))
    comment = 'On Arch Linux, connected sessions use 90% CPU while idle; a patched build uses 0-5% on the same profile.'
    allow(assessment).to receive(:ask_copilot).and_return(
      JSON.generate(labels: [], reply: nil, files: [], comment: comment)
    )

    assessment.run

    expect(assessment).to have_received(:mutate).with('addComment', subjectId: 'report-id',
                                                                    body: start_with(comment))
  end

  it 'does not treat reopening an issue as permission for another recap' do
    environment.merge!('GITHUB_EVENT_NAME' => 'issues', 'GITHUB_EVENT_PATH' => 'event.json')
    File.write('event.json', JSON.generate(action: 'reopened'))
    allow(assessment).to receive(:ask_copilot).and_return(
      JSON.generate(labels: [], reply: nil, files: [], comment: 'The report describes high idle CPU usage.')
    )

    assessment.run

    expect(assessment).not_to have_received(:mutate).with('addComment', anything)
  end

  it 'remembers that the initial issue assessment has already happened' do
    environment.merge!('GITHUB_EVENT_NAME' => 'issues', 'GITHUB_EVENT_PATH' => 'event.json',
                       'TRIAGE_STATE_DIR' => 'state')
    File.write('event.json', JSON.generate(action: 'opened'))
    comment = 'On Arch Linux, connected sessions use 90% CPU while idle.'
    allow(assessment).to receive(:ask_copilot).and_return(
      JSON.generate(labels: [], reply: nil, files: [], comment: comment)
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
      JSON.generate(labels: [], reply: nil, files: [], comment: 'The report describes high CPU usage.')
    )

    assessment.run

    expect(assessment).to have_received(:ask_copilot).twice
    expect(assessment).not_to have_received(:mutate).with('addComment', anything)
  end

  it 'rejects a forced generic next check even on an initial issue assessment' do
    environment.merge!('GITHUB_EVENT_NAME' => 'issues', 'GITHUB_EVENT_PATH' => 'event.json')
    File.write('event.json', JSON.generate(action: 'opened'))
    allow(assessment).to receive(:ask_copilot).and_return(
      JSON.generate(labels: [], reply: nil, files: [],
                    comment: 'CPU is high while idle. A useful next check is to inspect the redraw loop.')
    )

    assessment.run

    expect(assessment).not_to have_received(:mutate).with('addComment', anything)
  end

  [
    'The report describes a theme change that does not reach the app. Does restarting the app pick it up?',
    'The report establishes high CPU usage. A useful next check is whether restarting helps.',
    'The request is to package the app for NixOS.',
    'This was fixed in version 0.14.0.'
  ].each do |comment|
    it "suppresses a report-only statement while still applying labels: #{comment}" do
      allow(assessment).to receive(:read_report).and_return([item, [{ 'name' => 'bug', 'id' => 'bug-id' }]])
      allow(assessment).to receive(:ask_copilot).and_return(
        JSON.generate(labels: ['bug'], reply: nil, files: [], comment: comment)
      )

      assessment.run

      expect(assessment).not_to have_received(:mutate).with('addComment', anything)
      expect(assessment).to have_received(:mutate).with('addLabelsToLabelable', labelableId: 'report-id',
                                                                                labelIds: ['bug-id'])
      expect(assessment).to have_received(:mutate).with('addReaction', anything)
    end
  end

  it 'previews an initial assessment without publishing it' do
    environment['TRIAGE_DRY_RUN'] = 'true'
    allow(assessment).to receive(:ask_copilot).and_return(
      JSON.generate(labels: [], reply: nil, files: [], comment: 'Does restarting the app pick up the theme?')
    )

    assessment.run

    expect(assessment).to have_received(:ask_copilot).once
    expect(assessment).not_to have_received(:mutate)
  end

  it 'suppresses a generated assessment after a maintainer has answered' do
    item['comments']['nodes'] << { 'body' => 'I found the cause.', 'author' => { 'login' => 'owner' },
                                   'authorAssociation' => 'OWNER' }
    allow(assessment).to receive(:ask_copilot).and_return(
      JSON.generate(labels: [], reply: nil, files: [], comment: 'Does restarting the app pick up the theme?')
    )

    assessment.run

    expect(assessment).not_to have_received(:mutate).with('addComment', anything)
  end

  [false, ['A reply'], 'Read https://example.com', 'See [[lib/ruby_llm/tool.rb]].'].each do |comment|
    it "rejects an invalid report-based assessment: #{comment.inspect}" do
      allow(assessment).to receive(:ask_copilot).and_return(JSON.generate(labels: [], reply: nil, files: [],
                                                                          comment: comment))

      assessment.run

      expect(assessment).not_to have_received(:mutate)
    end
  end

  it 'rejects competing reply routes' do
    allow(assessment).to receive(:ask_copilot).and_return(JSON.generate(labels: [], reply: 'version', files: [],
                                                                        comment: 'Does restarting pick up the theme?'))

    assessment.run

    expect(assessment).not_to have_received(:mutate)
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
