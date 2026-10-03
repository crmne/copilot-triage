# frozen_string_literal: true

require_relative '../lib/assessment'

RSpec.describe IssueAssessment, 'with a project board' do
  let(:environment) do
    { 'GITHUB_REPOSITORY' => 'crmne/ruby_llm', 'TRIAGE_NUMBER' => '123', 'TRIAGE_KIND' => kind,
      'COPILOT_GITHUB_TOKEN' => 'test-copilot-token', 'TRIAGE_CONFIG' => 'board-triage.yml',
      'TRIAGE_PROJECT_TOKEN' => 'project-token' }
  end
  let(:kind) { 'issue' }
  let(:assessment) { described_class.new(environment) }
  let(:item) do
    { 'id' => 'report-id', 'title' => 'Streaming broke in 1.9', 'body' => 'Every stream now raises.',
      'closed' => false, 'author' => { 'login' => 'reporter' }, 'assignees' => { 'totalCount' => 0 },
      'comments' => { 'nodes' => [] } }
  end
  let(:labels) { [{ 'id' => 'bug-id', 'name' => 'bug' }, { 'id' => 'question-id', 'name' => 'question' }] }
  let(:decision) do
    { labels: ['bug'], reply: nil, comment: nil, sources: [], next_move: 'do', priority: 'high',
      next_step: 'Reproduce with the streaming example from the report.' }
  end
  let(:board) { instance_double(ProjectBoard, update: { 'column' => 'Do' }) }

  before do
    config = YAML.safe_load_file('triage.yml')
    config['board'] = { 'project' => 'https://github.com/users/crmne/projects/3', 'assign_urgent_to' => 'crmne' }
    File.write('board-triage.yml', YAML.dump(config))
    allow(assessment).to receive_messages(read_report: [item, labels], board: board)
    allow(assessment).to receive(:ask_copilot) { JSON.generate(decision) }
    allow(assessment).to receive(:mutate)
    allow(assessment).to receive(:github)
    allow(assessment).to receive(:puts)
  end

  it 'puts the issue in the column of the agent next move, with its priority and next step' do
    assessment.run

    expect(assessment).to have_received(:mutate).with('addReaction', anything).ordered
    expect(board).to have_received(:update).with('report-id', column: 'do', priority: 'high',
                                                              next_step: decision[:next_step],
                                                              movable: ProjectBoard::MOVABLE).ordered
    expect(assessment).not_to be_failed
  end

  %w[sign_off decide do].each do |move|
    it "maps the #{move} next move to its column" do
      decision[:next_move] = move

      assessment.run
      expect(board).to have_received(:update).with('report-id', hash_including(column: move))
    end
  end

  it 'moves an issue to Their move only when this run asked the reporter something' do
    decision.merge!(labels: ['question'], reply: 'version', next_move: 'theirs')

    assessment.run
    expect(board).to have_received(:update).with('report-id', hash_including(column: 'theirs'))
  end

  it 'keeps the column when the agent waits on the reporter without a reply' do
    decision[:next_move] = 'theirs'

    assessment.run
    expect(board).to have_received(:update).with('report-id', hash_including(column: nil))
  end

  it 'assigns urgent issues to the configured maintainer when nobody is assigned' do
    decision[:priority] = 'urgent'

    assessment.run
    expect(assessment).to have_received(:github).with('repos/crmne/ruby_llm/issues/123/assignees',
                                                      assignees: ['crmne'])
  end

  it 'does not reassign an issue that already has an assignee' do
    decision[:priority] = 'urgent'
    item['assignees']['totalCount'] = 1

    assessment.run
    expect(assessment).not_to have_received(:github)
  end

  it 'moves the card to Done when the issue closes, without calling the model' do
    File.write('closed.json', JSON.generate('action' => 'closed', 'issue' => { 'number' => 123, 'state' => 'closed' }))
    environment.merge!('GITHUB_EVENT_NAME' => 'issues', 'GITHUB_EVENT_PATH' => 'closed.json')
    allow(board).to receive(:finish).and_return('item-id')

    assessment.run
    expect(board).to have_received(:finish).with('report-id')
    expect(assessment).not_to have_received(:ask_copilot)
    expect(assessment).to have_received(:puts).with('Skipped: closed; moved its card to Done.')
  end

  it 'writes only to the board when quiet, as for a backfill' do
    environment['TRIAGE_QUIET'] = 'true'
    decision.merge!(labels: ['question'], reply: 'version', priority: 'urgent')

    assessment.run
    expect(board).to have_received(:update).with('report-id', hash_including(column: 'do', priority: 'urgent'))
    expect(assessment).not_to have_received(:mutate)
    expect(assessment).to have_received(:puts).with(include('"outcome":"quiet"'))
  end

  it "places the card by the maintainer's own comment without posting anything" do
    File.write('comment.json', JSON.generate(
                                 'action' => 'created', 'issue' => { 'number' => 123, 'state' => 'open' },
                                 'comment' => { 'node_id' => 'c1', 'author_association' => 'OWNER',
                                                'body' => 'Not now, after the redesign.',
                                                'user' => { 'login' => 'crmne' } },
                                 'sender' => { 'login' => 'crmne', 'type' => 'User' }
                               ))
    environment.merge!('GITHUB_EVENT_NAME' => 'issue_comment', 'GITHUB_EVENT_PATH' => 'comment.json',
                       'TRIAGE_DEBOUNCE_SECONDS' => '0')
    item['comments']['nodes'] << { 'id' => 'c1', 'createdAt' => '2026-10-03T00:00:00Z',
                                   'body' => 'Not now, after the redesign.',
                                   'author' => { 'login' => 'crmne' }, 'authorAssociation' => 'OWNER' }
    decision.merge!(next_move: 'not_now', comment: nil)

    assessment.run
    expect(assessment).to have_received(:ask_copilot).with(include('maintainer comment: place the card'))
    expect(assessment).not_to have_received(:mutate)
    expect(board).to have_received(:update).with('report-id', hash_including(column: 'not_now'))
  end

  it 'reports the board proposal in a dry run without writing' do
    environment['TRIAGE_DRY_RUN'] = 'true'

    assessment.run
    expect(board).not_to have_received(:update)
    expect(assessment).to have_received(:puts).with(start_with('Board proposal: {"column":"do"'))
  end

  it 'skips the board quietly until a project token is set' do
    environment['TRIAGE_PROJECT_TOKEN'] = ''

    assessment.run
    expect(board).not_to have_received(:update)
    expect(assessment).to have_received(:puts).with('Board: skipped; no project-token is set.')
    expect(assessment).not_to be_failed
  end

  it 'flags the card when the run leaves the item for a maintainer, since GitHub tells only who triggered it' do
    allow(assessment).to receive(:ask_copilot).and_return('{"not": "a decision"}')

    assessment.run
    expect(assessment).to be_failed
    expect(board).to have_received(:update).with(
      'report-id', column: 'do', movable: [nil],
                   next_step: 'Triage could not assess the latest update: its decision was invalid'
    )
  end

  it 'fails the job on a board error but keeps the published reply complete' do
    allow(board).to receive(:update).and_raise(ProjectBoard::Error, 'project 3 is not visible to the project-token')

    assessment.run
    expect(assessment).to be_failed
    expect(assessment).to have_received(:mutate).with('addReaction', anything)
    expect(assessment).to have_received(:puts)
      .with('Board update failed: project 3 is not visible to the project-token.')
  end

  it 'rejects a decision without the board fields' do
    decision.delete(:next_step)

    assessment.run
    expect(assessment).to be_failed
    expect(assessment).not_to have_received(:mutate)
    expect(board).to have_received(:update).once.with('report-id',
                                                      hash_including(next_step: start_with('Triage could not')))
  end

  it 'rejects a multi-line next step' do
    decision[:next_step] = "Reproduce.\nThen fix."

    assessment.run
    expect(assessment).to be_failed
    expect(board).to have_received(:update).once.with('report-id',
                                                      hash_including(next_step: start_with('Triage could not')))
  end

  it 'adds the board guidance and tool fields to the agent' do
    expect(assessment.send(:system_prompt)).to include('## Maintainer board')
    expect(assessment.send(:tools_settings, Dir.pwd)).to include(board: true)
  end

  it 'keeps the model environment free of the project token' do
    status = instance_double(Process::Status, success?: false, exitstatus: 1)
    allow(Open3).to receive(:capture3).and_return(['', '', status])
    allow(assessment).to receive(:ask_copilot).and_call_original

    assessment.send(:ask_copilot, 'prompt')
    expect(Open3).to have_received(:capture3).with(hash_including('TRIAGE_PROJECT_TOKEN' => nil), 'timeout',
                                                   any_args)
  end

  context 'with a discussion' do
    let(:kind) { 'discussion' }

    it 'leaves the board alone for a discussion that stays, since projects cannot hold discussions' do
      decision.merge!(labels: [], move_to_issue: false)

      assessment.run
      expect(board).not_to have_received(:update)
      expect(assessment).not_to be_failed
    end
  end
end
