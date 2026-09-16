# frozen_string_literal: true

require_relative '../lib/triage_event'

RSpec.describe TriageEvent do
  let(:event) do
    { 'action' => 'created', 'sender' => { 'type' => 'User' }, 'issue' => { 'state' => 'open' },
      'comment' => { 'body' => 'Thanks!', 'user' => { 'type' => 'User' }, 'author_association' => 'NONE' } }
  end

  it 'runs before a repository or configuration exists and writes an ineligible output' do
    Dir.mkdir('empty')
    File.write('empty/event.json', JSON.generate(event))
    script = File.expand_path('../lib/triage_event.rb', __dir__)
    output, errors, status = Open3.capture3(
      { 'GITHUB_EVENT_NAME' => 'issue_comment', 'GITHUB_EVENT_PATH' => 'event.json', 'GITHUB_OUTPUT' => 'output' },
      RbConfig.ruby, script, chdir: 'empty'
    )
    expect(status.success?).to be(true), errors
    expect(output).to include('acknowledgement')
    expect(File.read('empty/output')).to include('eligible=false')
  end

  it 'does not discard technical evidence after a thank-you' do
    event['comment']['body'] = "Thanks!\n```\nError: decoder failed\n```"
    expect(described_class.skip_reason('issue_comment', event)).to be_nil
  end

  it 'keeps explicit maintainer commands eligible' do
    event['comment'].merge!('body' => '/triage', 'author_association' => 'OWNER')
    expect(described_class.skip_reason('issue_comment', event)).to be_nil
  end

  it 'does not interpret a request to keep the bot as a stop request' do
    expect(described_class.stop_requested?('Please do not disable Copilot.')).to be(false)
  end

  it 'does not mistake code or quote examples for a command' do
    expect(described_class.command("```\n/triage unmute\n```\n> /triage")).to be_nil
  end

  it 'identifies a discussion reply by its parent for cache isolation' do
    event['discussion'] = { 'number' => 1 }
    event['comment'].merge!('id' => 200, 'parent_id' => 100)
    File.write('event.json', JSON.generate(event))
    script = File.expand_path('../lib/triage_event.rb', __dir__)
    _output, errors, status = Open3.capture3(
      { 'GITHUB_EVENT_NAME' => 'discussion_comment', 'GITHUB_EVENT_PATH' => 'event.json', 'GITHUB_OUTPUT' => 'output' },
      RbConfig.ruby, script
    )
    expect(status.success?).to be(true), errors
    expect(File.read('output')).to include('thread=100')
  end
end
