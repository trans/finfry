require "json"
require "./store"
require "./app"

module Finfry
  # A minimal MCP (Model Context Protocol) server over stdio, so any MCP client
  # (Claude Code, Claude Desktop, …) can read and update the ledger using
  # finfry's own commands as tools. JSON-RPC 2.0, one message per line.
  #
  # Approval is the client's job (MCP clients gate tool calls), so writes execute
  # immediately here — each still records its own undoable changeset, and the
  # account policy + balance guards still apply. `delete` and `accounts policy`
  # are not exposed (they're absent from the agent tool registry).
  class MCP
    PROTOCOL_VERSION = "2025-06-18"

    def initialize(store : Store, @input : IO = STDIN, @output : IO = STDOUT)
      # Commands run non-interactively; their output is captured per call and
      # returned in the tool result. Base output goes to STDERR so it can never
      # corrupt the JSON-RPC stream on @output.
      @app = App.new(store, out: STDERR, interactive: false)
    end

    def run : Nil
      while line = @input.gets
        line = line.strip
        handle(line) unless line.empty?
      end
    end

    private def handle(line : String) : Nil
      message =
        begin
          JSON.parse(line)
        rescue ex : JSON::ParseException
          return send_error(nil, -32700, "parse error")
        end

      id = message["id"]?
      begin
        case message["method"]?.try(&.as_s)
        when "initialize" then send_result(id, initialize_result(message))
        when "tools/list" then send_result(id, tools_list_result)
        when "tools/call" then send_result(id, tools_call_result(message))
        when "ping"       then send_result(id, "{}")
        else
          # Notifications (no id) need no reply; unknown requests get an error.
          send_error(id, -32601, "method not found") unless id.nil?
        end
      rescue ex
        send_error(id, -32603, "internal error: #{ex.message}") unless id.nil?
      end
    end

    # --- result builders ------------------------------------------------

    private def initialize_result(message : JSON::Any) : String
      requested = message["params"]?.try(&.["protocolVersion"]?).try(&.as_s) || PROTOCOL_VERSION
      %({"protocolVersion":#{requested.to_json},) +
        %("capabilities":{"tools":{}},) +
        %("serverInfo":{"name":"finfry","version":#{Finfry::VERSION.to_json}}})
    end

    private def tools_list_result : String
      String.build do |s|
        s << %({"tools":[)
        @app.agent_tools.each_with_index do |tool, i|
          s << "," if i > 0
          s << %({"name":#{tool.name.to_json},"description":#{tool.description.to_json},"inputSchema":#{tool.input_schema.to_json}})
        end
        s << "]}"
      end
    end

    private def tools_call_result(message : JSON::Any) : String
      params = message["params"]
      name = params["name"].as_s
      arguments = params["arguments"]? || JSON.parse("{}")
      output, error = @app.execute_tool(name, arguments)
      %({"content":[{"type":"text","text":#{output.to_json}}],"isError":#{error}})
    end

    # --- transport ------------------------------------------------------

    private def send_result(id : JSON::Any?, result : String) : Nil
      @output.puts %({"jsonrpc":"2.0","id":#{id_json(id)},"result":#{result}})
      @output.flush
    end

    private def send_error(id : JSON::Any?, code : Int32, message : String) : Nil
      @output.puts %({"jsonrpc":"2.0","id":#{id_json(id)},"error":{"code":#{code},"message":#{message.to_json}}})
      @output.flush
    end

    private def id_json(id : JSON::Any?) : String
      id ? id.to_json : "null"
    end
  end
end
