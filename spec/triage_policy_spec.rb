# frozen_string_literal: true

require_relative '../lib/triage_policy'

RSpec.describe TriagePolicy do
  let(:account) do
    "closing: auto\nduplicates: close\npull_requests:\n  reviews: private\n  out_of_scope: close\n" \
      "board:\n  project: https://github.com/users/crmne/projects/1\n  maintainer: crmne\n"
  end
  let(:status) { instance_double(Process::Status, success?: true) }

  before do
    allow(Open3).to receive(:capture3)
      .with({ 'GH_TOKEN' => 'token', 'GITHUB_TOKEN' => nil }, 'gh', 'api',
            'repos/crmne/github-automation/contents/triage/account.yml', '-H', 'Accept: application/vnd.github.raw')
      .and_return([account, '', status])
  end

  it "layers the repository's policy over the account's, section by section" do
    File.write('policy.yml', "extends: crmne/github-automation:triage/account.yml\nclosing: suggest\n" \
                             "pull_requests:\n  out_of_scope: suggest\nlabels:\n  bug: A problem.\n")

    expect(described_class.load('policy.yml', token: 'token')).to eq(
      'closing' => 'suggest', 'duplicates' => 'close', 'labels' => { 'bug' => 'A problem.' },
      'pull_requests' => { 'reviews' => 'private', 'out_of_scope' => 'suggest' },
      'board' => { 'project' => 'https://github.com/users/crmne/projects/1', 'maintainer' => 'crmne' }
    )
  end

  it "keeps the repository's own policy when the account's cannot be read" do
    allow(Open3).to receive(:capture3).and_return(['', 'Not Found', instance_double(Process::Status, success?: false)])
    File.write('policy.yml', "extends: crmne/github-automation:triage/account.yml\nclosing: suggest\n")

    expect { expect(described_class.load('policy.yml', token: 'token')).to eq('closing' => 'suggest') }
      .to output(/could not be read/).to_stderr
  end

  it 'reads a policy without extends as it is' do
    File.write('policy.yml', "closing: auto\n")
    expect(described_class.load('policy.yml')).to eq('closing' => 'auto')
  end
end
