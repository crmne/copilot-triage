# frozen_string_literal: true

require_relative '../lib/project_board'

RSpec.describe ProjectBoard do
  let(:board) { described_class.new({ 'project' => 'https://github.com/users/crmne/projects/3' }, token: 'project-token') }
  let(:status_options) { ProjectBoard::COLUMNS.values.map { |name| { 'id' => "option-#{name}", 'name' => name } } }
  let(:fields) do
    [{ 'id' => 'status-field', 'name' => 'Status', 'options' => status_options },
     { 'id' => 'priority-field', 'name' => 'Priority',
       'options' => ProjectBoard::PRIORITIES.values.map { |name| { 'id' => "option-#{name}", 'name' => name } } },
     { 'id' => 'next-field', 'name' => 'Next step', 'dataType' => 'TEXT' }]
  end
  let(:item) { { 'id' => 'item-id', 'status' => nil, 'priority' => nil } }
  let(:views) { [{ 'id' => 'view-all', 'name' => 'All repositories' }] }
  let(:writes) { [] }
  let(:mutations) { [] }
  let(:inputs) { [] }
  let(:content_items) { [] }

  before do
    allow(board).to receive(:graphql) do |query, **variables|
      if query.start_with?('mutation')
        mutations << query[/\{\s*(\w+)\(input/, 1]
        inputs << variables[:input]
      end
      if query.include?('projectV2(number')
        { 'data' => { 'user' => { 'projectV2' => { 'id' => 'project-id', 'fields' => { 'nodes' => fields },
                                                   'views' => { 'nodes' => views } } } } }
      elsif query.include?('node(id:')
        { 'data' => { 'node' => { 'projectItems' => { 'nodes' => content_items } } } }
      elsif query.include?('createProjectV2View')
        { 'data' => { 'createProjectV2View' => { 'projectV2View' => { 'id' => 'new-view' } } } }
      elsif query.include?('addProjectV2ItemById')
        { 'data' => { 'addProjectV2ItemById' => { 'item' => item } } }
      else
        writes << variables.fetch(:input).slice(:fieldId, :value)
        { 'data' => {} }
      end
    end
  end

  it 'adds a card and sets its column, priority, and next step' do
    changes = board.update('issue-id', column: 'fix', priority: 'high', next_step: 'Reproduce it.')

    expect(changes).to eq('column' => 'Fix', 'priority' => 'High', 'next_step' => 'Reproduce it.')
    expect(writes).to eq([{ fieldId: 'status-field', value: { singleSelectOptionId: 'option-Fix' } },
                          { fieldId: 'priority-field', value: { singleSelectOptionId: 'option-High' } },
                          { fieldId: 'next-field', value: { text: 'Reproduce it.' } }])
  end

  %w[Backlog Someday].each do |column|
    it "leaves a card the maintainer put in #{column}" do
      item['status'] = { 'name' => column }

      expect(board.update('issue-id', column: 'decide')).to eq({})
      expect(writes).to be_empty
    end
  end

  it 'brings an archived card back when its issue reopens' do
    item['isArchived'] = true
    item['status'] = { 'name' => 'Done' }

    expect(board.update('issue-id', column: 'decide')).to eq('column' => 'Answer or decide')
    expect(mutations).to eq(%w[addProjectV2ItemById unarchiveProjectV2Item updateProjectV2ItemFieldValue])
  end

  it 'moves cards between its own columns' do
    item['status'] = { 'name' => 'Approve' }

    expect(board.update('issue-id', column: 'waiting')).to eq('column' => 'Waiting on others')
  end

  it 'sorts what needs the maintainer by effort, then the rest' do
    expect(ProjectBoard::COLUMNS.values)
      .to eq(['Approve', 'Answer or decide', 'Review', 'Fix', 'Waiting on others', 'Backlog', 'Done'])
  end

  it 'changes nothing when the project already has the board shape' do
    expect(board.set_up).to eq([])
    expect(mutations).to be_empty
  end

  it 'sets up an empty project: columns, fields, and the All repositories view' do
    status_options.replace([{ 'id' => 'todo', 'name' => 'Todo' }, { 'id' => 'done', 'name' => 'Done' }])
    fields.pop(2)
    views.clear

    expect(board.set_up).to eq(['columns', 'Priority', 'Next step', 'All repositories view'])
    expect(mutations).to eq(%w[updateProjectV2Field createProjectV2Field createProjectV2Field createProjectV2View
                               updateProjectV2View])
  end

  it 'replaces retired columns but keeps columns of the maintainer own' do
    status_options.replace((['Needs me', 'Someday', 'Done'] + ProjectBoard::COLUMNS.values.first(2))
                             .map { |name| { 'id' => name, 'name' => name } })
    board.set_up
    sent = inputs.first.fetch(:singleSelectOptions).map { |option| option[:name] }
    expect(sent).to eq(ProjectBoard::COLUMNS.values + ['Someday'])
  end

  it 'adds a view for a repository once' do
    expect(board.ensure_repository_view('crmne/spotifast')).to eq('spotifast view')
    views << { 'id' => 'view-spotifast', 'name' => 'spotifast' }
    board.instance_variable_set(:@project, nil)
    expect(board.ensure_repository_view('crmne/spotifast')).to be_nil
  end

  it 'moves the card of a closed issue or pull request on this board only to Done' do
    content_items.push({ 'id' => 'other-item', 'project' => { 'id' => 'other-project' } },
                       { 'id' => 'our-item', 'project' => { 'id' => 'project-id' } })

    expect(board.finish('issue-id')).to eq('our-item')
    expect(writes).to eq([{ fieldId: 'status-field', value: { singleSelectOptionId: 'option-Done' } }])
  end

  it 'archives finished items' do
    board.archive('item-id')
    expect(mutations).to eq(['archiveProjectV2Item'])
  end

  it 'raises a priority but never lowers one' do
    item['priority'] = { 'name' => 'High' }

    expect(board.update('issue-id', priority: 'normal')).to eq({})
    expect(board.update('issue-id', priority: 'urgent')).to eq('priority' => 'Urgent')
  end

  it 'skips optional fields the project does not have' do
    fields.pop(2)

    expect(board.update('issue-id', column: 'fix', priority: 'urgent', next_step: 'Fix it.'))
      .to eq('column' => 'Fix')
  end

  it 'uses renamed columns' do
    board = described_class.new({ 'project' => 'https://github.com/orgs/acme/projects/1',
                                  'columns' => { 'decide' => 'Inbox' } }, token: 'project-token')

    expect(board.column_name('decide')).to eq('Inbox')
    expect(board.column_key('Inbox')).to eq('decide')
    expect(board.column_key('Waiting on others')).to eq('waiting')
  end

  it 'explains a missing column option' do
    status_options.reject! { |option| option['name'] == 'Fix' }

    expect { board.update('issue-id', column: 'fix') }
      .to raise_error(ProjectBoard::Error, /Status needs an option named Fix/)
  end

  it 'rejects missing tokens, malformed URLs, and unknown columns' do
    expect { described_class.new({ 'project' => 'https://github.com/users/crmne/projects/3' }, token: '') }
      .to raise_error(ProjectBoard::Error, /project-token/)
    expect { described_class.new({ 'project' => 'https://example.com/projects/3' }, token: 'token') }
      .to raise_error(ProjectBoard::Error, /project URL/)
    expect do
      described_class.new({ 'project' => 'https://github.com/users/crmne/projects/3',
                            'columns' => { 'later' => 'Later' } }, token: 'token')
    end.to raise_error(ProjectBoard::Error, /unknown board columns: later/)
  end

  it 'sends requests with the project token only' do
    allow(board).to receive(:graphql).and_call_original
    status = instance_double(Process::Status, success?: false)
    allow(Open3).to receive(:capture3).and_return(['{"errors":[{"message":"Resource not accessible"}]}', '', status])

    expect { board.id }.to raise_error(ProjectBoard::Error, 'GitHub project request failed: Resource not accessible')
    expect(Open3).to have_received(:capture3).with({ 'GH_TOKEN' => 'project-token', 'GITHUB_TOKEN' => nil },
                                                   'gh', 'api', 'graphql', '--input', '-', stdin_data: anything)
  end

  it 'accepts a next step only as one short line' do
    expect(described_class.next_step?('Decide on Fedora support.')).to be(true)
    expect(described_class.next_step?("Two\nlines")).to be(false)
    expect(described_class.next_step?(' ')).to be(false)
    expect(described_class.next_step?('x' * 161)).to be(false)
  end
end
