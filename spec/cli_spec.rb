# frozen_string_literal: true

require 'socket'
require_relative '../lib/assessment'

RSpec.describe 'Issue assessment Copilot integration', type: :task do
  let(:requests) { [] }
  let(:decision) do
    { labels: [], reply: nil, comment: nil, sources: [], related_issue: nil, relationship: nil, mute: false }
  end
  let(:steps) { [['submit_decision', decision]] }
  let(:final_text) { 'Done.' }

  around do |example|
    skip 'Install Copilot CLI to run this offline integration check' unless copilot_installed?

    server = TCPServer.new('127.0.0.1', 0)
    worker = serve_model(server, requests, steps)
    previous = ENV.to_h
    ENV.update('COPILOT_OFFLINE' => 'true', 'COPILOT_PROVIDER_TYPE' => 'openai',
               'COPILOT_PROVIDER_BASE_URL' => "http://127.0.0.1:#{server.addr[1]}/v1",
               'COPILOT_PROVIDER_WIRE_API' => 'completions', 'COPILOT_PROVIDER_WIRE_MODEL' => 'gpt-5.6-luna')
    example.run
  ensure
    ENV.replace(previous) if previous
    worker&.kill&.join
    server&.close
  end

  it 'exposes only scoped read-only tools through the installed CLI, using an offline fake provider' do
    assessment = IssueAssessment.new('GITHUB_REPOSITORY' => 'crmne/ruby_llm', 'TRIAGE_NUMBER' => '123',
                                     'COPILOT_GITHUB_TOKEN' => 'offline-test', 'TRIAGE_CONFIG' => 'triage.yml')
    allow(assessment).to receive(:puts)

    response = assessment.send(:ask_copilot, 'Assess the report and submit your decision.')

    expect(JSON.parse(response)).to eq(decision.transform_keys(&:to_s))
    expect(requests.size).to eq(2)
    names = requests.first.fetch('tools').map { |tool| tool.dig('function', 'name') }
    expect(names.size).to eq(5)
    expect(names.join(' ')).to include('search_repository', 'search_issues', 'list_releases', 'read_evidence',
                                       'submit_decision')
  end

  it 'lets the agent search, refine its query, read evidence, and answer in one native session' do
    File.write('docs/forwarding.md',
               'Right-click the message or picture, choose Forward, then select the destination chat.')
    steps.unshift(['search_repository', { query: 'forwarding' }], ['search_repository', { query: 'Forward' }],
                  ['read_evidence', { reference: 'file:docs/forwarding.md' }])
    assessment = IssueAssessment.new('GITHUB_REPOSITORY' => 'crmne/zapfast', 'TRIAGE_NUMBER' => '46',
                                     'COPILOT_GITHUB_TOKEN' => 'offline-test', 'TRIAGE_CONFIG' => 'triage.yml')
    allow(assessment).to receive(:puts)

    assessment.send(:ask_copilot, 'Find whether message forwarding is supported.')

    expect(requests.size).to eq(5)
    tool_messages = requests.last.fetch('messages').select { |message| message['role'] == 'tool' }.to_json
    expect(tool_messages).to include('destination chat', 'file:docs/forwarding.md')
    expect(assessment.instance_variable_get(:@tool_ledger).fetch('evidence')).to have_key('file:docs/forwarding.md')
  end

  context 'when the model emits JSON as final text instead of calling submit_decision' do
    let(:steps) { [] }
    let(:final_text) { JSON.generate(decision) }

    it 'does not accept the unsubmitted decision' do
      assessment = IssueAssessment.new('GITHUB_REPOSITORY' => 'crmne/zapfast', 'TRIAGE_NUMBER' => '46',
                                       'COPILOT_GITHUB_TOKEN' => 'offline-test', 'TRIAGE_CONFIG' => 'triage.yml')
      allow(assessment).to receive(:puts)

      expect(assessment.send(:ask_copilot, 'Assess the report.')).to be_nil
      expect(requests.size).to eq(1)
    end
  end

  it 'runs from another checkout and rereads GitHub before publishing' do
    Dir.mkdir('bin')
    File.write('bin/gh', <<~RUBY)
      #!/usr/bin/env ruby
      require 'json'
      payload = JSON.parse(STDIN.read)
      abort 'Unexpected mutation' if payload.fetch('query').include?('mutation')
      File.open('github-reads.txt', 'a') { |file| file.puts('read') }
      item = { id: 'item', title: 'Bug', body: 'A reproduction', closed: false,
               author: { login: 'reporter' }, comments: { nodes: [] } }
      puts JSON.generate(data: { repository: { issue: item, labels: { nodes: [] } } })
    RUBY
    File.chmod(0o755, 'bin/gh')
    environment = {
      'PATH' => "#{Dir.pwd}/bin:#{ENV.fetch('PATH')}", 'GITHUB_REPOSITORY' => 'crmne/ruby_llm',
      'COPILOT_GITHUB_TOKEN' => 'offline-test', 'TRIAGE_CONFIG' => 'triage.yml',
      'TRIAGE_NUMBER' => '123', 'TRIAGE_DRY_RUN' => 'true', 'TRIAGE_CACHE_DIR' => 'cache'
    }
    script = File.expand_path('../lib/assessment.rb', __dir__)

    first, errors, status = Open3.capture3(environment, RbConfig.ruby, script)
    expect(status.success?).to be(true), errors
    expect(first).to include('"labels":[]')
    expect(File.readlines('github-reads.txt').size).to eq(2)
    expect(requests.size).to eq(2)
    expect(requests.first.fetch('tools').size).to eq(5)
  end

  def copilot_installed?
    ENV.fetch('PATH').split(File::PATH_SEPARATOR).any? { |directory| File.executable?(File.join(directory, 'copilot')) }
  end

  def serve_model(server, requests, steps)
    Thread.new do
      loop do
        socket = server.accept
        socket.gets
        headers = {}
        while (line = socket.gets) != "\r\n"
          name, value = line.split(':', 2)
          headers[name.downcase] = value.strip
        end
        requests << JSON.parse(socket.read(Integer(headers.fetch('content-length'))))
        body = completion(requests.last, steps.shift)
        socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n")
        socket.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
        socket.close
      end
    end
  end

  def completion(request, step)
    delta = { role: 'assistant', content: final_text }
    if step
      name = request.fetch('tools').find { |tool| tool.dig('function', 'name').end_with?(step.first) }
                    .dig('function', 'name')
      delta = { role: 'assistant', tool_calls: [{ index: 0, id: "call-#{requests.size}", type: 'function',
                                                  function: { name: name, arguments: JSON.generate(step.last) } }] }
    end
    chunk = {
      id: 'offline-completion', object: 'chat.completion.chunk', created: 1, model: 'gpt-5.6-luna',
      choices: [{ index: 0, finish_reason: step ? 'tool_calls' : 'stop', delta: delta }]
    }
    "data: #{JSON.generate(chunk)}\n\ndata: [DONE]\n\n"
  end
end
