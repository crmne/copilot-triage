# frozen_string_literal: true

require_relative 'triage_tools'

# Minimal MCP stdio transport. Copilot, not this process, owns the agent loop.
class TriageToolServer
  def initialize(tools)
    @tools = tools
  end

  def run(input = $stdin, output = $stdout)
    input.each_line do |line|
      request = JSON.parse(line)
      next unless request.key?('id')

      result = case request['method']
               when 'initialize'
                 { protocolVersion: '2024-11-05', capabilities: { tools: {} },
                   serverInfo: { name: 'triage', version: '1' } }
               when 'ping' then {}
               when 'tools/list' then { tools: TriageTools.definitions }
               when 'tools/call'
                 @tools.call(request.dig('params', 'name'), request.dig('params', 'arguments') || {})
               end
      response = if result
                   { jsonrpc: '2.0', id: request['id'], result: result }
                 else
                   { jsonrpc: '2.0', id: request['id'], error: { code: -32_601, message: 'Method not found' } }
                 end
      output.puts(JSON.generate(response))
      output.flush
    end
  end
end

if $PROGRAM_NAME == __FILE__
  settings = JSON.parse(File.read(ARGV.fetch(0)))
  tools = TriageTools.new(**settings.transform_keys(&:to_sym))
  TriageToolServer.new(tools).run
end
