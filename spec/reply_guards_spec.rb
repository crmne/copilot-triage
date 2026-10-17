# frozen_string_literal: true

require_relative '../lib/assessment'

RSpec.describe 'Reply guards' do
  let(:config) { YAML.safe_load_file('triage.yml') }
  let(:environment) do
    { 'GITHUB_REPOSITORY' => 'crmne/example', 'TRIAGE_NUMBER' => '1', 'TRIAGE_CONFIG' => 'triage.yml',
      'GITHUB_STEP_SUMMARY' => 'summary.md' }
  end
  let(:assessment) { IssueAssessment.new(environment) }
  let(:item) do
    { 'id' => 'report-id', 'title' => 'Playback pauses at random', 'body' => 'Playback pauses every few minutes.',
      'closed' => false, 'author' => { '__typename' => 'User', 'login' => 'reporter' },
      'comments' => { 'nodes' => [] } }
  end
  let(:labels) { [{ 'id' => 'bug-id', 'name' => 'bug' }] }

  before do
    File.write('triage.yml', config.to_yaml)
    allow(assessment).to receive_messages(read_report: [item, labels])
    allow(assessment).to receive(:mutate)
    allow(assessment).to receive(:puts)
  end

  def decide(comment, **decision)
    allow(assessment).to receive(:ask_copilot).and_return(
      JSON.generate({ labels: ['bug'], reply: nil, sources: [], comment: comment }.merge(decision))
    )
  end

  [
    'The log shows audio underruns; please investigate this as a playback bug.',
    'Confirmed: the cache is cleared before the write finishes.',
    'This is a scoped enhancement that needs a product decision.',
    'This is a distinct enhancement for maintainer prioritization.',
    'The reporter found a confirmed playback bug in the queue.'
  ].each do |comment|
    it "keeps quiet instead of posting #{comment.inspect}" do
      decide(comment)

      assessment.run

      expect(assessment).not_to be_failed
      expect(assessment).to have_received(:mutate).with('addLabelsToLabelable', labelableId: 'report-id',
                                                                                labelIds: ['bug-id'])
      expect(assessment).not_to have_received(:mutate).with('addComment', anything)
      expect(File.read('summary.md')).to include('Dropped the reply: it was addressed to the maintainer.')
    end
  end

  it 'still tells a contributor that a new setting needs maintainer approval' do
    comment = 'A new setting needs maintainer approval in the issue before a pull request.'
    decide(comment)

    assessment.run

    expect(assessment).to have_received(:mutate).with('addComment', subjectId: 'report-id',
                                                                    body: start_with(comment))
  end
end
