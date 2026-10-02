# frozen_string_literal: true

require 'json'
require 'open3'

# The maintainer's project board. The first three columns are the maintainer's
# moves, by effort: sign off on a prepared result, decide, do the work. The
# rest need nothing from them: someone else's move, not now, done. Finished
# work is archived after a while. Not now and any column of the maintainer's
# own are never overridden.
class ProjectBoard
  class Error < RuntimeError; end

  COLUMNS = {
    'sign_off' => 'Sign off', 'decide' => 'Decide', 'do' => 'Do', 'theirs' => 'Their move',
    'not_now' => 'Not now', 'done' => 'Done'
  }.freeze
  DESCRIPTIONS = {
    'sign_off' => 'Say yes to a prepared result: merge a ready pull request or accept a resolution',
    'decide' => 'Use your judgment: scope, feature requests, design, answers only you can give',
    'do' => 'Use your hands: review a pull request waiting on you, fix a bug, finish your own work',
    'theirs' => 'Someone else has the next step: a contributor, a reporter, a reviewer, or upstream',
    'not_now' => 'Nobody acts until you choose: accepted but not scheduled, your roadmap',
    'done' => 'Closed or merged; archived after a while'
  }.freeze
  COLORS = { 'sign_off' => 'GREEN', 'decide' => 'PINK', 'do' => 'ORANGE', 'theirs' => 'YELLOW',
             'not_now' => 'GRAY', 'done' => 'PURPLE' }.freeze
  # Columns of v0.8 renamed in place, keeping their IDs so cards stay put.
  RENAMED = { 'Approve' => 'sign_off', 'Answer or decide' => 'decide', 'Fix' => 'do',
              'Waiting on others' => 'theirs', 'Backlog' => 'not_now' }.freeze
  # Columns from earlier versions, removed when the board is set up again;
  # their cards are placed again.
  RETIRED = ['Needs me', 'Waiting on them', 'Blocked', 'Ready to merge', 'In progress', 'Review'].freeze
  MOVABLE = [nil, 'sign_off', 'decide', 'do', 'theirs', 'done'].freeze
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

  # Draft cards of this board by title, such as the one for a failing main
  # branch: { title => item ID }.
  def drafts
    cursor = nil
    found = {}
    loop do
      query = <<~GRAPHQL
        query($id: ID!, $after: String) {
          node(id: $id) { ... on ProjectV2 { items(first: 100, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes { id isArchived content { ... on DraftIssue { title } } }
          } } }
        }
      GRAPHQL
      page = graphql(query, id: id, after: cursor).dig('data', 'node', 'items')
      page.fetch('nodes').each do |node|
        title = node.dig('content', 'title')
        found[title] = node.fetch('id') if title && !node['isArchived']
      end
      break unless page.dig('pageInfo', 'hasNextPage')

      cursor = page.dig('pageInfo', 'endCursor')
    end
    found
  end

  # Adds a draft card and places it; returns its item ID.
  def add_draft(title, body:, column:, priority: nil, next_step: nil)
    query = 'mutation($input: AddProjectV2DraftIssueInput!) ' \
            '{ addProjectV2DraftIssue(input: $input) { projectItem { id } } }'
    item = graphql(query, input: { projectId: id, title: title, body: body })
           .dig('data', 'addProjectV2DraftIssue', 'projectItem', 'id')
    set_column(item, column)
    set_option(item, PRIORITY_FIELD, PRIORITIES.fetch(priority)) if priority && field(PRIORITY_FIELD)
    set_value(item, NEXT_STEP_FIELD, text: next_step) if next_step && field(NEXT_STEP_FIELD)
    item
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
    existing = status.fetch('options')
    current = existing.map { |option| option.fetch('name') }
    wanted = COLUMNS.keys.map { |key| column_name(key) }
    own = current - wanted - RETIRED - RENAMED.keys
    return if current == wanted + own

    # An option sent without its ID is recreated, which clears it from every
    # card; existing and renamed columns keep their IDs, so cards keep their places.
    options = COLUMNS.keys.map do |key|
      option = existing.find { |entry| entry['name'] == column_name(key) } ||
               existing.find { |entry| RENAMED[entry['name']] == key }
      { id: option&.fetch('id'), name: column_name(key), color: COLORS.fetch(key),
        description: DESCRIPTIONS.fetch(key) }.compact
    end
    options += own.map do |name|
      option = existing.find { |entry| entry['name'] == name }
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
