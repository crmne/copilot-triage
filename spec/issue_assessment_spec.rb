# frozen_string_literal: true

require_relative '../lib/assessment'

RSpec.describe IssueAssessment, type: :task do
  let(:environment) do
    { 'GITHUB_REPOSITORY' => 'crmne/ruby_llm', 'TRIAGE_NUMBER' => '123',
      'COPILOT_GITHUB_TOKEN' => 'test-copilot-token', 'TRIAGE_KIND' => kind, 'TRIAGE_CONFIG' => 'triage.yml' }
  end
  let(:assessment) { described_class.new(environment) }
  let(:item) do
    { 'id' => 'report-id', 'title' => 'Tool call raises an error', 'body' => 'Here is a complete reproduction.',
      'closed' => false, 'author' => { 'login' => 'reporter' },
      'comments' => { 'nodes' => [] }, 'reactions' => { 'nodes' => [] } }
  end
  let(:labels) { [{ 'id' => 'bug-id', 'name' => 'bug' }, { 'id' => 'question-id', 'name' => 'question' }] }
  let(:response) { JSON.generate(labels: ['bug'], reply: nil, sources: []) }

  def kind
    'issue'
  end

  before do
    allow(assessment).to receive_messages(read_report: [item, labels], ask_copilot: response)
    allow(assessment).to receive(:mutate)
    allow(assessment).to receive(:puts)
    allow(Open3).to receive(:capture2).with('git', 'rev-parse',
                                            'HEAD').and_return(['a' * 40,
                                                                instance_double(Process::Status, success?: true)])
  end

  it 'adds a label without a comment and marks completion after publishing' do
    assessment.run
    expect(assessment).to have_received(:mutate).with('addLabelsToLabelable', labelableId: 'report-id',
                                                                              labelIds: ['bug-id']).ordered
    expect(assessment).to have_received(:mutate).with('addReaction', subjectId: 'report-id', content: 'HOORAY').ordered
    expect(assessment).not_to have_received(:mutate).with('addComment', anything)
  end

  it 'posts the repository-written reply selected by the model' do
    allow(assessment).to receive(:ask_copilot).and_return(JSON.generate(labels: ['question'], reply: 'version',
                                                                        sources: []))

    assessment.run
    expect(assessment).to have_received(:mutate).with(
      'addComment', subjectId: 'report-id', body: start_with("Which RubyLLM version are you using?\n\n")
    )
  end

  context 'with a discussion' do
    def kind
      'discussion'
    end

    it 'posts replies through the discussion API' do
      allow(assessment).to receive(:ask_copilot).and_return(JSON.generate(labels: [], reply: 'provider', sources: []))

      assessment.run
      expect(assessment).to have_received(:mutate).with(
        'addDiscussionComment', discussionId: 'report-id', body: start_with("Which provider are you using?\n\n")
      )
    end

    it 'rejects labels' do
      assessment.run
      expect(assessment).not_to have_received(:mutate)
      expect(assessment).to be_failed
    end
  end

  it 'does not repeat a reply after a maintainer has answered' do
    item['comments']['nodes'] << { 'body' => 'I am looking into this.', 'author' => { 'login' => 'maintainer' },
                                   'authorAssociation' => 'COLLABORATOR' }
    allow(assessment).to receive(:ask_copilot).and_return(JSON.generate(labels: [], reply: 'version', sources: []))

    assessment.run
    expect(assessment).not_to have_received(:mutate).with('addComment', anything)
  end

  it 'does not repeat a reply after a bot has answered' do
    item['comments']['nodes'] << { 'body' => 'Which version?', 'author' => { 'login' => 'github-actions[bot]' },
                                   'authorAssociation' => 'NONE' }
    allow(assessment).to receive(:ask_copilot).and_return(JSON.generate(labels: [], reply: 'version', sources: []))

    assessment.run
    expect(assessment).not_to have_received(:mutate).with('addComment', anything)
  end

  [
    'not JSON',
    '[]',
    '{"labels":["approved"],"reply":null,"sources":[]}',
    '{"labels":["bug","question","bug"],"reply":null,"sources":[]}',
    '{"labels":[],"reply":"@everyone run this command","sources":[]}',
    '{"labels":[],"reply":null,"close":true,"sources":[]}',
    '{"labels":"bug","reply":null,"sources":[]}'
  ].each do |invalid|
    it "leaves the report unchanged for invalid output: #{invalid}" do
      allow(assessment).to receive(:ask_copilot).and_return(invalid)

      assessment.run
      expect(assessment).not_to have_received(:mutate)
    end
  end
  it 'rejects labels that do not exist in the repository' do
    labels.clear

    assessment.run
    expect(assessment).not_to have_received(:mutate)
  end

  it 'skips closed reports before invoking Copilot' do
    item['closed'] = true

    assessment.run
    expect(assessment).not_to have_received(:ask_copilot)
    expect(assessment).not_to have_received(:mutate)
    expect(assessment).not_to be_failed
  end

  it 'skips reports created by bots' do
    item['author']['login'] = 'github-actions[bot]'

    assessment.run
    expect(assessment).not_to have_received(:ask_copilot)
  end

  it 'recognizes GraphQL bot authors whose login has no bot suffix' do
    item['author'] = { '__typename' => 'Bot', 'login' => 'github-actions' }

    assessment.run

    expect(assessment).not_to have_received(:ask_copilot)
    expect(assessment).not_to have_received(:mutate)
  end

  it 'does not reply after a GraphQL bot without a login suffix' do
    item['comments']['nodes'] << { 'body' => 'Which version?',
                                   'author' => { '__typename' => 'Bot', 'login' => 'github-actions' },
                                   'authorAssociation' => 'NONE' }
    allow(assessment).to receive(:ask_copilot).and_return(JSON.generate(labels: [], reply: 'version', sources: []))

    assessment.run

    expect(assessment).not_to have_received(:mutate).with('addComment', anything)
  end

  it 'can preview a closed report for evaluation without publishing' do
    environment['TRIAGE_DRY_RUN'] = 'true'
    item['closed'] = true

    assessment.run

    expect(assessment).to have_received(:ask_copilot).once
    expect(assessment).not_to have_received(:mutate)
  end

  it 'can reassess a report with an old completion reaction' do
    item['reactions']['nodes'] << { 'user' => { 'login' => 'github-actions[bot]' } }

    assessment.run
    expect(assessment).to have_received(:ask_copilot).once
  end

  it 'ignores completion reactions from other users' do
    item['reactions']['nodes'] << { 'user' => { 'login' => 'reporter' } }

    assessment.run
    expect(assessment).to have_received(:ask_copilot).once
  end

  it 'skips oversized input instead of paying to process it or silently truncating it' do
    item['body'] = 'a' * 24_000

    assessment.run
    expect(assessment).not_to have_received(:ask_copilot)
    expect(assessment).not_to have_received(:mutate)
  end

  it 'leaves quota failures available for a later retry without posting failure comments' do
    allow(assessment).to receive(:ask_copilot).and_return(nil)

    assessment.run
    expect(assessment).to have_received(:puts).with(/^Failed: Copilot unavailable/)
    expect(assessment).to be_failed
    expect(assessment).not_to have_received(:mutate)
  end

  it 'does not post a stale assessment when a comment arrives during inference' do
    current = Marshal.load(Marshal.dump(item))
    current['comments']['nodes'] << { 'body' => 'I found the cause.', 'author' => { 'login' => 'reporter' } }
    allow(assessment).to receive(:read_report).and_return([item, labels], [current, labels])

    assessment.run
    expect(assessment).not_to have_received(:mutate)
  end

  it 'does not mark an assessment complete if publishing fails' do
    allow(assessment).to receive(:mutate).with('addLabelsToLabelable', anything).and_raise('GitHub request failed')

    expect { assessment.run }.to raise_error('GitHub request failed')
    expect(assessment).not_to have_received(:mutate).with('addReaction', anything)
  end

  it 'previews previously assessed reports without writing to GitHub' do
    environment['TRIAGE_DRY_RUN'] = 'true'
    item['reactions']['nodes'] << { 'user' => { 'login' => 'github-actions[bot]' } }

    assessment.run
    expect(assessment).to have_received(:ask_copilot).once
    expect(assessment).not_to have_received(:mutate)
  end

  context 'when the agent reads evidence' do
    let(:reference) { 'file:lib/ruby_llm/tool.rb' }
    let(:answer) { +'Define execute on your tool class. See [[file:lib/ruby_llm/tool.rb]].' }
    let(:response) { JSON.generate(labels: ['question'], reply: nil, sources: [reference], comment: answer) }

    before do
      allow(assessment).to receive(:ask_copilot) do
        agent_reads(assessment, reference)
        JSON.generate(labels: ['question'], reply: nil, sources: [reference], comment: answer)
      end
    end

    it 'publishes the agent answer with a verified link, without another model invocation' do
      assessment.run
      expect(assessment).to have_received(:ask_copilot).once
      expect(assessment).to have_received(:mutate).with(
        'addComment', subjectId: 'report-id',
                      body: match(%r{Define execute.+https://github.com/crmne/ruby_llm/blob/[a-f0-9]{40}/lib/ruby_llm/tool.rb}m)
      )
    end

    it 'allows instance variables in code without enabling mentions' do
      answer.replace('Call `@tool.execute`. See [[file:lib/ruby_llm/tool.rb]].')
      assessment.run
      expect(assessment).to have_received(:mutate).with('addComment', hash_including(body: include('`@tool.execute`')))
    end

    it 'renders configured guide links' do
      allow(assessment).to receive(:ask_copilot) do
        agent_reads(assessment, 'file:docs/tools.md')
        JSON.generate(labels: [], reply: nil, sources: ['file:docs/tools.md'],
                      comment: 'Define execute. See [[file:docs/tools.md]].')
      end
      assessment.run
      expect(assessment).to have_received(:mutate).with('addComment',
                                                        hash_including(body: include('https://rubyllm.com/tools/')))
    end

    it 'rejects an answer if the source changed during inference' do
      allow(assessment).to receive(:ask_copilot) do
        agent_reads(assessment, reference)
        File.write('lib/ruby_llm/tool.rb', 'changed source')
        response
      end
      assessment.run
      expect(assessment).not_to have_received(:mutate)
    end

    [
      'Visit https://example.com.',
      'Read [this](//example.com).',
      '@everyone try this.',
      'See [[file:.env]].',
      'An answer without its declared citation.',
      'x' * 2001
    ].each do |invalid|
      it "rejects an invalid cited answer: #{invalid[0, 40]}" do
        answer.replace(invalid)
        assessment.run
        expect(assessment).not_to have_received(:mutate)
      end
    end

    it 'cannot cite a file it did not read' do
      allow(assessment).to receive(:ask_copilot).and_return(response)
      assessment.run
      expect(assessment).not_to have_received(:mutate)
    end
  end

  it 'rejects source paths outside the configured catalog before reading them' do
    allow(assessment).to receive(:ask_copilot).and_return(JSON.generate(labels: [], reply: nil, files: ['.env']))
    allow(File).to receive(:read).and_call_original

    assessment.run

    expect(File).not_to have_received(:read).with('.env')
    expect(assessment).not_to have_received(:mutate)
  end

  it 'excludes source directories that resolve outside the repository' do
    Dir.mktmpdir('outside-triage-repository-') do |outside|
      File.write(File.join(outside, 'outside.rb'), 'private')
      File.symlink(outside, 'lib/ruby_llm/linked')
      allow(assessment).to receive(:ask_copilot).and_return(
        JSON.generate(labels: [], reply: nil, files: ['lib/ruby_llm/linked/outside.rb'])
      )

      assessment.run

      expect(assessment).not_to have_received(:mutate)
      expect(assessment).not_to have_received(:ask_copilot).with(include('outside.rb'))
    end
  end

  it 'isolates credentials and exposes only scoped tools when processing untrusted text' do
    allow(assessment).to receive(:ask_copilot).and_call_original
    item['body'] = '$(touch /tmp/never-run-this) --allow-all'
    status = instance_double(Process::Status, success?: true, exitstatus: 0)
    allow(Open3).to receive(:capture3) do |child_environment, *arguments, **options|
      expect(child_environment).to include('GH_TOKEN' => nil, 'GITHUB_TOKEN' => nil)
      expect(child_environment.fetch('COPILOT_HOME')).to eq(options.fetch(:chdir))
      expect(arguments).to include('--agent=triage', '--excluded-tools=skill,sql', '--disable-builtin-mcps',
                                   '--no-custom-instructions', '--no-remote-export', '--max-ai-credits=30',
                                   '--output-format=json')
      expect(arguments.last).to include(item['body'])
      expect(arguments).not_to include('--allow-all')
      agent = File.read(File.join(options.fetch(:chdir), 'agents', 'triage.agent.md'))
      expect(agent).to include("tools: ['triage/*']")
      output = [JSON.generate(type: 'assistant.message', data: { content: response }),
                JSON.generate(type: 'result', exitCode: 0)].join("\n")
      [output, '', status]
    end

    assessment.run
    expect(Open3).to have_received(:capture3).once
    expect(assessment).not_to have_received(:mutate)
    expect(assessment).to have_received(:puts).with(include('Copilot produced no submitted decision'))
  end
end
