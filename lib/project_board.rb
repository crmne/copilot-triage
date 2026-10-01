# frozen_string_literal: true

require 'json'
require 'open3'

# The maintainer's project board. Columns say whose move it is. Triage moves cards
# only between its own columns; Backlog, Blocked, In progress, and any custom
# column are maintainer decisions it never overrides.
class ProjectBoard
  class Error < RuntimeError; end

  COLUMNS = {
    'needs_maintainer' => 'Needs me', 'waiting_on_reporter' => 'Waiting on them', 'blocked' => 'Blocked',
    'ready_to_merge' => 'Ready to merge', 'backlog' => 'Backlog', 'in_progress' => 'In progress', 'done' => 'Done'
  }.freeze
  MOVABLE = [nil, 'needs_maintainer', 'waiting_on_reporter', 'ready_to_merge', 'done'].freeze
  PRIORITIES = { 'urgent' => 'Urgent', 'high' => 'High', 'normal' => 'Normal' }.freeze
  STATUS_FIELD = 'Status'
  PRIORITY_FIELD = 'Priority'
  NEXT_STEP_FIELD = 'Next step'

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
  end

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
            id
            status: fieldValueByName(name: "#{STATUS_FIELD}") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
            priority: fieldValueByName(name: "#{PRIORITY_FIELD}") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
          }
        }
      }
    GRAPHQL
    graphql(query, project: id, content: content_id).fetch('data').fetch('addProjectV2ItemById').fetch('item')
  end

  def set_column(item_id, column)
    set_option(item_id, STATUS_FIELD, column_name(column))
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

  def project
    @project ||= begin
      query = <<~GRAPHQL
        query($owner: String!, $number: Int!) {
          #{@owner_type}(login: $owner) {
            projectV2(number: $number) {
              id
              fields(first: 50) {
                nodes {
                  ... on ProjectV2FieldCommon { id name dataType }
                  ... on ProjectV2SingleSelectField { options { id name } }
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
