# frozen_string_literal: true

require 'json'
require 'open3'

# The maintainer's project board. Four columns sort what needs the maintainer by
# effort (approve, answer or decide, review, fix); everything else waits on
# someone else or sits in the backlog. Finished work goes to Done and is
# archived after a while. Backlog and any column of the maintainer's own are
# never overridden.
class ProjectBoard
  class Error < RuntimeError; end

  COLUMNS = {
    'approve' => 'Approve', 'decide' => 'Answer or decide', 'review' => 'Review', 'fix' => 'Fix',
    'waiting' => 'Waiting on others', 'backlog' => 'Backlog', 'done' => 'Done'
  }.freeze
  DESCRIPTIONS = {
    'approve' => 'A quick yes: merge, accept, or confirm',
    'decide' => 'A question to answer or a decision to make',
    'review' => 'A change worth reading closely',
    'fix' => 'Work for you to do or finish',
    'waiting' => 'Someone else has the next move',
    'backlog' => 'Valid, nobody has to act now',
    'done' => 'Finished; archived after a while'
  }.freeze
  COLORS = { 'approve' => 'GREEN', 'decide' => 'PINK', 'review' => 'BLUE', 'fix' => 'ORANGE',
             'waiting' => 'YELLOW', 'backlog' => 'GRAY', 'done' => 'PURPLE' }.freeze
  # Columns from earlier versions, removed when the board is set up again.
  RETIRED = ['Needs me', 'Waiting on them', 'Blocked', 'Ready to merge', 'In progress'].freeze
  MOVABLE = [nil, 'approve', 'decide', 'review', 'fix', 'waiting', 'done'].freeze
  PRIORITIES = { 'urgent' => 'Urgent', 'high' => 'High', 'normal' => 'Normal' }.freeze
  STATUS_FIELD = 'Status'
  PRIORITY_FIELD = 'Priority'
  NEXT_STEP_FIELD = 'Next step'
  ALL_VIEW = 'All repositories'

  def self.next_step?(text)
    text.is_a?(String) && !text.strip.empty? && text.bytesize <= 160 && !text.match?(/[\r\n\0]/)
  end

  def initialize(settings, token:)
    raise Error, 'board needs a project-token; see the README' if token.to_s.empty?

    @token = token
    match = %r{\Ahttps://github\.com/(users|orgs)/([\w.-]+)/projects/(\d+)/?\z}.match(settings.fetch('project', ''))
    raise Error, 'board.project must be a GitHub project URL' unless match

    @owner_type = match[1] == 'users' ? 'user' : 'organization'
    @owner = match[2]
    @number = Integer(match[3], 10)
    columns = settings.fetch('columns', {})
    raise Error, "unknown board columns: #{(columns.keys - COLUMNS.keys).join(', ')}" unless
      (columns.keys - COLUMNS.keys).empty?

    @columns = COLUMNS.merge(columns)
    @archive_after = Integer(settings.fetch('archive_after_days', 7))
  end

  attr_reader :archive_after

  def id
    project.fetch('id')
  end

  def column_name(key)
    @columns.fetch(key)
  end

  # Maps an option name back to its column key; an unknown name stays as-is, so
  # it is never in MOVABLE.
  def column_key(name)
    name && (@columns.key(name) || name)
  end

  # Adds the issue or pull request (idempotent) and applies the proposed values.
  # Returns the changes made, keyed by field.
  def update(content_id, column: nil, priority: nil, next_step: nil, movable: MOVABLE)
    item = add(content_id)
    current = column_key(item.dig('status', 'name'))
    changes = {}
    if column && current != column && movable.include?(current)
      set_column(item.fetch('id'), column)
      changes['column'] = column_name(column)
    end
    if priority && raise_priority?(item.dig('priority', 'name'), priority) && field(PRIORITY_FIELD)
      set_option(item.fetch('id'), PRIORITY_FIELD, PRIORITIES.fetch(priority))
      changes['priority'] = PRIORITIES.fetch(priority)
    end
    if next_step && field(NEXT_STEP_FIELD)
      set_value(item.fetch('id'), NEXT_STEP_FIELD, text: next_step)
      changes['next_step'] = next_step
    end
    changes
  end

  def add(content_id)
    query = <<~GRAPHQL
      mutation($project: ID!, $content: ID!) {
        addProjectV2ItemById(input: { projectId: $project, contentId: $content }) {
          item {
            id isArchived
            status: fieldValueByName(name: "#{STATUS_FIELD}") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
            priority: fieldValueByName(name: "#{PRIORITY_FIELD}") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
          }
        }
      }
    GRAPHQL
    item = graphql(query, project: id, content: content_id).fetch('data').fetch('addProjectV2ItemById').fetch('item')
    unarchive(item.fetch('id')) if item['isArchived']
    item
  end

  # A reopened issue or pull request comes back from the archive.
  def unarchive(item_id)
    query = 'mutation($input: UnarchiveProjectV2ItemInput!) ' \
            '{ unarchiveProjectV2Item(input: $input) { clientMutationId } }'
    graphql(query, input: { projectId: id, itemId: item_id })
  end

  def set_column(item_id, column)
    set_option(item_id, STATUS_FIELD, column_name(column))
  end

  # Finished work leaves the board; archived items stay searchable in the project.
  def archive(item_id)
    graphql('mutation($input: ArchiveProjectV2ItemInput!) { archiveProjectV2Item(input: $input) { clientMutationId } }',
            input: { projectId: id, itemId: item_id })
  end

  # Moves the card of a closed issue or pull request to Done, if it has one on
  # this board, and returns the item's ID.
  def finish(content_id)
    query = <<~GRAPHQL
      query($id: ID!) {
        node(id: $id) {
          ... on Issue { projectItems(first: 20) { nodes { id project { id } } } }
          ... on PullRequest { projectItems(first: 20) { nodes { id project { id } } } }
        }
      }
    GRAPHQL
    items = graphql(query, id: content_id).dig('data', 'node', 'projectItems', 'nodes').to_a
    item = items.find { |entry| entry.dig('project', 'id') == id }
    return unless item

    set_column(item.fetch('id'), 'done')
    item.fetch('id')
  end

  # Brings the project to the board's shape: the columns in order, the Priority
  # and Next step fields, and the All repositories view. Changes nothing that is
  # already right, keeps columns of the maintainer's own, and returns what it did.
  def set_up
    [ensure_columns, ensure_field(PRIORITY_FIELD, 'SINGLE_SELECT', priority_options),
     ensure_field(NEXT_STEP_FIELD, 'TEXT'), ensure_view(ALL_VIEW, '')].compact
  end

  # A board view of one repository, created when it first has cards. Returns the
  # view's name when it was created.
  def ensure_repository_view(repository)
    ensure_view(repository.split('/', 2).last, "repo:#{repository}")
  end

  def graphql(query, **variables)
    output, _errors, status = Open3.capture3({ 'GH_TOKEN' => @token, 'GITHUB_TOKEN' => nil },
                                             'gh', 'api', 'graphql', '--input', '-',
                                             stdin_data: JSON.generate(query: query, variables: variables))
    result = begin
      JSON.parse(output)
    rescue JSON::ParserError
      nil
    end
    return result if status.success? && result.is_a?(Hash) && !result['errors']

    message = result.is_a?(Hash) ? Array(result['errors']).filter_map { |error| error['message'] }.first : nil
    raise Error, "GitHub project request failed#{": #{message}" if message}"
  end

  private

  def ensure_columns
    status = field(STATUS_FIELD)
    current = status.fetch('options').map { |option| option.fetch('name') }
    wanted = COLUMNS.keys.map { |key| column_name(key) }
    own = current - wanted - RETIRED
    return if current == wanted + own

    # An option sent without its ID is recreated, which clears it from every
    # card; existing columns keep their IDs, so cards keep their places.
    existing = status.fetch('options').to_h { |option| [option.fetch('name'), option] }
    options = COLUMNS.keys.map do |key|
      { id: existing.dig(column_name(key), 'id'), name: column_name(key), color: COLORS.fetch(key),
        description: DESCRIPTIONS.fetch(key) }.compact
    end
    options += own.map do |name|
      option = existing.fetch(name)
      { id: option['id'], name: name, color: option['color'] || 'GRAY', description: option['description'].to_s }
    end
    graphql('mutation($input: UpdateProjectV2FieldInput!) { updateProjectV2Field(input: $input) { clientMutationId } }',
            input: { fieldId: status.fetch('id'), singleSelectOptions: options })
    reload
    'columns'
  end

  def priority_options
    PRIORITIES.values.zip(%w[RED YELLOW GRAY]).map { |name, color| { name: name, color: color, description: '' } }
  end

  def ensure_field(name, type, options = nil)
    return if field(name)

    input = { projectId: id, dataType: type, name: name }
    input[:singleSelectOptions] = options if options
    graphql('mutation($input: CreateProjectV2FieldInput!) { createProjectV2Field(input: $input) { clientMutationId } }',
            input: input)
    reload
    name
  end

  def ensure_view(name, filter)
    return if project.dig('views', 'nodes').any? { |view| view['name'] == name }

    query = 'mutation($input: CreateProjectV2ViewInput!) ' \
            '{ createProjectV2View(input: $input) { projectV2View { id } } }'
    created = graphql(query, input: { projectId: id, name: name, layout: 'BOARD_LAYOUT' })
    view = created.dig('data', 'createProjectV2View', 'projectV2View', 'id')
    visible = [STATUS_FIELD, PRIORITY_FIELD, NEXT_STEP_FIELD, 'Title', 'Repository', 'Assignees', 'Labels']
              .filter_map { |field_name| field(field_name)&.fetch('id') }
    graphql('mutation($input: UpdateProjectV2ViewInput!) { updateProjectV2View(input: $input) { clientMutationId } }',
            input: { viewId: view, filter: filter, configuration: { visibleFieldIds: visible } })
    reload
    "#{name} view"
  end

  def raise_priority?(current, proposed)
    ranks = PRIORITIES.values
    current_rank = ranks.index(current)
    current_rank.nil? || ranks.index(PRIORITIES.fetch(proposed)) < current_rank
  end

  def set_option(item_id, field_name, option_name)
    option = field(field_name)&.fetch('options', [])&.find { |entry| entry['name'] == option_name }
    raise Error, "project field #{field_name} needs an option named #{option_name}" unless option

    set_value(item_id, field_name, singleSelectOptionId: option.fetch('id'))
  end

  def set_value(item_id, field_name, **value)
    query = <<~GRAPHQL
      mutation($input: UpdateProjectV2ItemFieldValueInput!) {
        updateProjectV2ItemFieldValue(input: $input) { clientMutationId }
      }
    GRAPHQL
    graphql(query, input: { projectId: id, itemId: item_id, fieldId: field(field_name).fetch('id'), value: value })
  end

  def field(name)
    project.fetch('fields').fetch('nodes').find { |entry| entry['name'] == name }
  end

  def reload
    @project = nil
  end

  def project
    @project ||= begin
      query = <<~GRAPHQL
        query($owner: String!, $number: Int!) {
          #{@owner_type}(login: $owner) {
            projectV2(number: $number) {
              id
              views(first: 100) { nodes { id name } }
              fields(first: 50) {
                nodes {
                  ... on ProjectV2FieldCommon { id name dataType }
                  ... on ProjectV2SingleSelectField { options { id name color description } }
                }
              }
            }
          }
        }
      GRAPHQL
      found = graphql(query, owner: @owner, number: @number).dig('data', @owner_type, 'projectV2')
      raise Error, "project #{@owner}/#{@number} is not visible to the project-token" unless found
      raise Error, "project needs a single-select #{STATUS_FIELD} field" unless
        found.dig('fields', 'nodes')&.any? { |entry| entry['name'] == STATUS_FIELD && entry['options'] }

      found
    end
  end
end
