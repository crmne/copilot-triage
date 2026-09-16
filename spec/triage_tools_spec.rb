# frozen_string_literal: true

require_relative '../lib/triage_tools'
require_relative '../lib/tool_server'
require 'stringio'

RSpec.describe TriageTools do
  let(:config) { YAML.safe_load_file('triage.yml') }
  let(:tools) do
    described_class.new(root: Dir.pwd, repository: 'owner/project', config: config, ledger_path: 'ledger.json')
  end

  def call(name, **arguments)
    result = tools.call(name, arguments.transform_keys(&:to_s))
    raise result.inspect if result[:isError]

    JSON.parse(result.fetch(:content).first.fetch(:text))
  end

  it 'searches literal text and supplies a nearby offset without guessing relevance' do
    File.write('docs/forward.md',
               "Frontmatter\n#{"unrelated line\n" * 800}Right-click a message to forward it.\n")
    result = call('search_repository', query: 'forward')
    match = result.fetch('results').first
    expect(match).to include('reference' => 'file:docs/forward.md', 'line' => 802)
    read = call('read_evidence', reference: match['reference'], offset: match['offset'])
    expect(read['content']).to include('Right-click')
  end

  it 'supports a directory filter and listing files without loading their text into context' do
    result = call('search_repository', query: '', path: 'docs/')
    expect(result['results'].map { |entry| entry['reference'] }).to eq(['file:docs/tools.md'])
    expect(result.to_json).not_to include('class Tool')
  end

  it 'paginates search results rather than silently discarding the tail' do
    File.write('docs/many.md', "match here\n" * 30)
    first = call('search_repository', query: 'match')
    second = call('search_repository', query: 'match', offset: first.fetch('next_offset'))
    expect(first['results'].size).to eq(10)
    expect(second['results'].first['line']).to eq(11)
  end

  it 'bounds every result and allows reading the remainder of large text' do
    File.write('docs/large.md', "#{'日"' * 4000}THE END")
    offset = 0
    collected = +''
    loop do
      result = call('read_evidence', reference: 'file:docs/large.md', offset: offset)
      expect(JSON.generate(result).bytesize).to be <= described_class::MAX_RESULT_BYTES
      collected << result.fetch('content')
      offset = result['next_offset']
      break unless offset
    end
    expect(collected).to eq(File.read('docs/large.md'))
    expect(tools.ledger.dig('evidence', 'file:docs/large.md', 'complete')).to be(true)
  end

  it 'rejects secrets, traversal, external URLs, and symlink escapes' do
    File.write('.env', 'SECRET')
    File.symlink(File.expand_path('.env'), 'docs/linked.md')
    ['file:.env', 'file:../.env', "file:#{Dir.pwd}/.env", 'https://example.com',
     'file:docs/linked.md'].each do |reference|
      expect(tools.call('read_evidence', { 'reference' => reference })).to include(isError: true)
    end
    expect(tools.ledger['evidence']).to be_empty
  end

  it 'rejects parent-directory symlinks outside the configured checkout' do
    Dir.mktmpdir('outside-tools-') do |outside|
      File.write(File.join(outside, 'outside.rb'), 'PRIVATE')
      File.symlink(outside, 'lib/ruby_llm/link')
      expect(tools.call('read_evidence',
                        { 'reference' => 'file:lib/ruby_llm/link/outside.rb' })).to include(isError: true)
    end
  end

  it 'scopes issue search to the configured repository even with injected qualifiers' do
    allow(tools).to receive(:api).and_return('items' => [], 'total_count' => 0)
    call('search_issues', query: 'repo:someone/private OR secret', state: 'closed')
    expect(tools).to have_received(:api) do |endpoint|
      query = URI.decode_www_form(URI(endpoint).query).to_h.fetch('q')
      expect(query).to include('"repo" "someone" "private" "OR" "secret" repo:owner/project is:issue is:closed')
    end
  end

  it 'returns small issue previews and a pagination indicator' do
    issue = { 'number' => 42, 'title' => 'Theme', 'body' => 'x' * 50_000, 'state' => 'open' }
    allow(tools).to receive(:api).and_return('total_count' => 12, 'items' => [issue])
    result = call('search_issues', query: 'theme')
    expect(result['results'].first['preview'].bytesize).to eq(600)
    expect(result['next_page']).to eq(2)
    expect(tools.ledger['evidence']).to be_empty
  end

  it 'excludes draft releases and preserves prerelease metadata' do
    allow(tools).to receive(:api).and_return([
                                               { 'id' => 1, 'tag_name' => 'v1.0', 'body' => 'Draft', 'draft' => true,
                                                 'prerelease' => false },
                                               { 'id' => 2, 'tag_name' => 'v1.1-rc1', 'body' => 'Candidate',
                                                 'draft' => false, 'prerelease' => true }
                                             ])
    expected = { 'reference' => 'release:2', 'version' => 'v1.1-rc1', 'preview' => 'Candidate',
                 'prerelease' => true, 'published_at' => nil }
    expect(call('list_releases')['results']).to eq([expected])
  end

  it 'cannot read draft releases or pull requests as evidence' do
    allow(tools).to receive(:api).and_return('draft' => true)
    expect(tools.call('read_evidence', { 'reference' => 'release:1' })).to include(isError: true)
    allow(tools).to receive(:api).and_return('pull_request' => {})
    expect(tools.call('read_evidence', { 'reference' => 'issue:1' })).to include(isError: true)
  end

  it 'returns recoverable errors without pretending GitHub is empty' do
    allow(tools).to receive(:api).and_raise(IOError, 'GitHub read failed')
    expect(tools.call('list_releases', {})).to include(isError: true)
  end

  it 'returns a small recoverable error for a malformed GitHub response' do
    status = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture3).and_return(['invalid data ' * 1000, '', status])

    result = tools.call('list_releases', {})

    expect(result).to include(isError: true)
    expect(result.to_json.bytesize).to be < 200
    expect(tools.ledger['evidence']).to be_empty
  end

  it 'limits evidence calls while still allowing the final structured decision' do
    described_class::MAX_CALLS.times { call('search_repository', query: '') }
    expect(tools.call('search_repository', { 'query' => '' })).to include(isError: true)
    expect(call('submit_decision', labels: [], reply: nil, comment: nil, sources: [],
                                   related_issue: nil, relationship: nil, mute: false)).to eq('accepted' => true)
    expect(tools.call('list_releases', {})).to include(isError: true)
  end

  it 'validates structured decision fields and rejects unknown properties' do
    expect(tools.call('submit_decision', { 'labels' => 'bug' })).to include(isError: true)
    expect(tools.call('read_evidence',
                      { 'reference' => 'file:docs/tools.md', 'url' => 'evil' })).to include(isError: true)
    expect(tools.ledger).not_to have_key('decision')
  end

  it 'explains rejected arguments so the agent can correct a read' do
    result = tools.call('read_evidence', { 'reference' => 'file:docs/tools.md', 'maxLength' => 6000 })
    expect(result).to include(isError: true)
    expect(result[:content].first[:text]).to include('Unknown arguments: maxLength',
                                                     'Allowed arguments: reference, offset')
    expect(call('read_evidence', reference: 'file:docs/tools.md')['content']).to include('Define `execute`')
  end

  it 'keeps submission open when the proposed duplicate has not been read' do
    decision = { 'labels' => [], 'reply' => nil, 'comment' => 'Both reports describe the same failure.',
                 'sources' => [], 'related_issue' => 42, 'relationship' => 'duplicate', 'mute' => false }
    result = tools.call('submit_decision', decision)
    expect(result).to include(isError: true)
    expect(result[:content].first[:text]).to include('Read issue:42 completely')
    expect(tools.ledger).not_to have_key('decision')
  end

  it 'uses standard MCP initialization, listing, and tool calls over stdio' do
    requests = [
      { jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2024-11-05' } },
      { jsonrpc: '2.0', method: 'notifications/initialized' },
      { jsonrpc: '2.0', id: 2, method: 'tools/list' },
      { jsonrpc: '2.0', id: 3, method: 'tools/call',
        params: { name: 'search_repository', arguments: { query: '' } } }
    ]
    input = StringIO.new("#{requests.map { |request| JSON.generate(request) }.join("\n")}\n")
    output = StringIO.new
    TriageToolServer.new(tools).run(input, output)
    responses = output.string.lines.map { |line| JSON.parse(line) }
    expect(responses.map { |response| response['id'] }).to eq([1, 2, 3])
    expect(responses[1].dig('result', 'tools').size).to eq(5)
    expect(responses[2].dig('result', 'content', 0, 'text')).to include('file:docs/tools.md')
  end
end
