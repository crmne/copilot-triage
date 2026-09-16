# frozen_string_literal: true

require_relative '../lib/assessment'

RSpec.describe 'Bounded evidence requests' do
  let(:environment) do
    { 'GITHUB_REPOSITORY' => 'owner/project', 'TRIAGE_NUMBER' => '1', 'TRIAGE_CONFIG' => 'triage.yml',
      'TRIAGE_EVIDENCE_DIR' => 'evidence' }
  end
  let(:assessment) { IssueAssessment.new(environment) }
  let(:item) do
    { 'id' => 'issue-1', 'title' => 'Images fail on Windows', 'body' => 'All images fail in every chat.',
      'closed' => false, 'author' => { 'login' => 'reporter' }, 'comments' => { 'nodes' => [] } }
  end
  let(:release) do
    { 'id' => 'release-1', 'tagName' => 'v1.2.3', 'name' => 'Image fixes',
      'description' => 'Fixed inline images failing in every chat on Windows.',
      'url' => 'https://github.com/owner/project/releases/tag/v1.2.3',
      'publishedAt' => '2026-09-16T12:00:00Z', 'isDraft' => false, 'isPrerelease' => false }
  end
  let(:selection) do
    JSON.generate(labels: [], reply: nil, files: [], lookup: [{ tool: 'releases', query: 'Windows images' }])
  end
  let(:answer) do
    JSON.generate(comment: 'Fixed in v1.2.3; see [[releases:release-1]].', sources: ['releases:release-1'])
  end

  before do
    allow(assessment).to receive_messages(read_report: [item, []], puts: nil, mutate: nil)
    allow(assessment).to receive(:ask_copilot).and_return(selection, answer)
    allow(assessment).to receive(:github) do |_endpoint, query:, variables:|
      if variables.key?(:ids)
        { 'data' => { 'nodes' => [release] } }
      else
        expect(query).to include('releases(first: 20')
        { 'data' => { 'repository' => { 'releases' => { 'nodes' => [release] } } } }
      end
    end
  end

  it 'retrieves release evidence only when requested and links the verified release' do
    assessment.run
    expect(assessment).to have_received(:ask_copilot).twice
    expect(assessment).to have_received(:ask_copilot).with(include(release['description']))
    expect(assessment).to have_received(:mutate).with('addComment', subjectId: 'issue-1',
                                                                    body: include('[release notes]', release['url']))
    expect(assessment).to have_received(:github).with('graphql', query: include('nodes(ids:'),
                                                                 variables: { ids: ['release-1'] })
  end

  it 'does not retrieve release or resolved-issue metadata for a silent assessment' do
    allow(assessment).to receive(:ask_copilot).and_return(JSON.generate(labels: [], reply: nil, files: []))
    assessment.run
    expect(assessment).not_to have_received(:github)
  end

  it 'reuses the evidence cache while revalidating the cited record before posting' do
    allow(assessment).to receive(:ask_copilot).and_return(selection, answer, selection, answer)
    assessment.run
    assessment.run
    expect(assessment).to have_received(:github).with('graphql', query: include('releases(first:'),
                                                                 variables: anything).once
    expect(assessment).to have_received(:github).with('graphql', query: include('nodes(ids:'),
                                                                 variables: anything).twice
  end

  it 'does not publish stale release evidence' do
    changed = release.merge('description' => 'Corrected notes')
    allow(assessment).to receive(:github).with('graphql', query: include('nodes(ids:'), variables: anything)
                                         .and_return('data' => { 'nodes' => [changed] })
    assessment.run
    expect(assessment).not_to have_received(:mutate)
  end

  it 'excludes draft releases and avoids an answer call when there are no matches' do
    release['isDraft'] = true
    assessment.run
    expect(assessment).to have_received(:ask_copilot).once
    expect(assessment).not_to have_received(:mutate).with('addComment', anything)
  end

  it 'keeps closed-issue evidence separate from duplicate closure' do
    resolved = { 'id' => 'resolved-1', 'number' => 42, 'title' => 'Images fail',
                 'body' => 'Use the native image viewer.',
                 'url' => 'https://github.com/owner/project/issues/42', 'closed' => true,
                 'closedAt' => '2026-09-16T12:00:00Z', 'stateReason' => 'COMPLETED' }
    allow(assessment).to receive(:github).and_return(
      { 'data' => { 'repository' => { 'issues' => { 'nodes' => [resolved] } } } },
      { 'data' => { 'nodes' => [resolved] } }
    )
    allow(assessment).to receive(:ask_copilot).and_return(
      JSON.generate(labels: [], reply: nil, files: [], lookup: [{ tool: 'resolved_issues', query: 'images' }]),
      JSON.generate(comment: 'Use the native image viewer; see [[resolved_issues:resolved-1]].',
                    sources: ['resolved_issues:resolved-1'])
    )
    assessment.run
    expect(assessment).to have_received(:mutate).with('addComment', subjectId: 'issue-1', body: include('[#42]'))
    expect(assessment).not_to have_received(:mutate).with('closeIssue', anything)
  end

  it 'rejects a URL outside the current repository even in returned evidence' do
    release['url'] = 'https://example.com/untrusted'
    assessment.run
    expect(assessment).not_to have_received(:mutate)
  end

  [
    [{ tool: 'shell', query: 'echo bad' }],
    [{ tool: 'releases', query: 'x' * 201 }],
    [{ tool: 'releases', query: 'images', url: 'https://example.com' }],
    Array.new(3) { { tool: 'docs', query: 'images' } },
    'releases', false
  ].each do |lookup|
    it "rejects an invalid evidence request #{lookup.inspect}" do
      allow(assessment).to receive(:ask_copilot).and_return(JSON.generate(labels: [], reply: nil, files: [],
                                                                          lookup: lookup))
      assessment.run
      expect(assessment).not_to have_received(:github)
      expect(assessment).not_to have_received(:mutate)
    end
  end

  it 'extracts relevant source text within the evidence budget, including content near the end' do
    File.write('docs/large.md', "#{"Unrelated introduction.\n" * 1000}\nWindows images need the native viewer.\n")
    excerpt = assessment.send(:source_excerpt, 'docs/large.md', 'Windows images')
    expect(excerpt).to include('Windows images need the native viewer')
    expect(excerpt.bytesize).to be <= 6000
  end

  it 'refreshes an excerpt when the source changes' do
    path = 'docs/large.md'
    File.write(path, "#{"Unrelated introduction.\n" * 1000}\nWindows images: old guidance.\n")
    first = assessment.send(:source_excerpt, path, 'Windows images')
    File.write(path, "#{"Unrelated introduction.\n" * 1000}\nWindows images: new guidance.\n")
    second = assessment.send(:source_excerpt, path, 'Windows images')
    expect(first).to include('old guidance')
    expect(second).to include('new guidance')
  end
end
