require "http/client"
require "json"
require "./models"
require "./recurrence"

module Finfry
  # The seam between finfry and an AI service. Backed by raw HTTPS calls to the
  # Claude Messages API with tool use (no SDK dependency). finfry exposes its
  # commands as tools; the model reads the ledger and proposes changes, and the
  # caller's block executes each tool call. The whole provider conversation lives
  # behind `converse`, so the backing implementation can later be swapped for a
  # multi-provider library without touching the command layer.
  #
  # Request building and turn parsing are pure (testable without network).
  class AI
    API_URL           = "https://api.anthropic.com/v1/messages"
    ANTHROPIC_VERSION = "2023-06-01"
    DEFAULT_MODEL     = "claude-opus-4-8"
    MAX_TOKENS        = 4096
    MAX_TURNS         =   16

    # A tool the model may call: a finfry command name, a description, and the
    # JSON Schema of its input.
    struct ToolDef
      getter name : String
      getter description : String
      getter input_schema : JSON::Any

      def initialize(@name, @description, @input_schema)
      end
    end

    # A tool call the model made.
    struct ToolCall
      getter id : String
      getter name : String
      getter input : JSON::Any

      def initialize(@id, @name, @input)
      end
    end

    # The result of running a tool, fed back to the model.
    struct ToolOutcome
      getter content : String
      getter? error : Bool

      def initialize(@content, @error = false)
      end
    end

    # One model turn: text it emitted, tool calls it made, and whether it's done.
    struct Turn
      getter text : String
      getter tool_calls : Array(ToolCall)
      getter? done : Bool

      def initialize(@text, @tool_calls, @done)
      end
    end

    def initialize(@api_key : String, @model : String = DEFAULT_MODEL)
    end

    def self.from_env : AI
      key = ENV["ANTHROPIC_API_KEY"]?
      if key.nil? || key.empty?
        raise Error.new("ANTHROPIC_API_KEY is not set — export your Anthropic API key to use `finfry ai`")
      end
      new(key, ENV["FINFRY_MODEL"]? || DEFAULT_MODEL)
    end

    # Drive a tool-use conversation. The block runs each tool call and returns
    # its outcome (reads execute and return output; writes can be deferred).
    # Returns the model's final text answer.
    def converse(prompt : String, *, system : String, tools : Array(ToolDef), & : ToolCall -> ToolOutcome) : String
      messages = [user_text_message(prompt)]
      answer = [] of String
      turns = 0

      loop do
        turns += 1
        raise Error.new("the AI took too many steps (#{MAX_TURNS}); try a simpler request") if turns > MAX_TURNS

        response = request(system, tools, messages)
        turn = AI.parse_turn(response)
        answer << turn.text unless turn.text.empty?
        break if turn.done?

        messages << assistant_echo(response)
        messages << tool_results_message(turn.tool_calls.map { |call| {call, (yield call)} })
      end

      answer.join("\n")
    end

    # Pure: extract text, tool calls, and done-ness from a response document.
    def self.parse_turn(response : JSON::Any) : Turn
      content = response["content"]?.try(&.as_a?) || [] of JSON::Any
      text = content
        .select { |b| b["type"]?.try(&.as_s) == "text" }
        .map { |b| b["text"].as_s }
        .join("\n")
      calls = content.compact_map do |b|
        next unless b["type"]?.try(&.as_s) == "tool_use"
        ToolCall.new(b["id"].as_s, b["name"].as_s, b["input"]? || JSON.parse("{}"))
      end
      done = response["stop_reason"]?.try(&.as_s) != "tool_use" || calls.empty?
      Turn.new(text, calls, done)
    end

    # --- request plumbing -----------------------------------------------

    private def request(system : String, tools : Array(ToolDef), messages : Array(String)) : JSON::Any
      response =
        begin
          HTTP::Client.post(API_URL, headers: request_headers, body: build_request(system, tools, messages))
        rescue ex : IO::Error
          raise Error.new("could not reach the AI service: #{ex.message}")
        end

      unless response.success?
        raise Error.new("AI service error (HTTP #{response.status_code}): #{error_message(response.body)}")
      end

      json = JSON.parse(response.body)
      raise Error.new("the AI declined to process that request") if json["stop_reason"]?.try(&.as_s) == "refusal"
      json
    end

    # The JSON request body. Public for testing.
    def build_request(system : String, tools : Array(ToolDef), messages : Array(String)) : String
      JSON.build do |json|
        json.object do
          json.field "model", @model
          json.field "max_tokens", MAX_TOKENS
          json.field "system", system
          json.field "tools" do
            json.array do
              tools.each do |tool|
                json.object do
                  json.field "name", tool.name
                  json.field "description", tool.description
                  json.field "input_schema" { json.raw tool.input_schema.to_json }
                end
              end
            end
          end
          json.field "messages" { json.array { messages.each { |m| json.raw m } } }
        end
      end
    end

    private def user_text_message(text : String) : String
      %({"role":"user","content":#{text.to_json}})
    end

    private def assistant_echo(response : JSON::Any) : String
      %({"role":"assistant","content":#{response["content"].to_json}})
    end

    private def tool_results_message(pairs : Array(Tuple(ToolCall, ToolOutcome))) : String
      String.build do |s|
        s << %({"role":"user","content":[)
        pairs.each_with_index do |(call, outcome), i|
          s << "," if i > 0
          s << %({"type":"tool_result","tool_use_id":#{call.id.to_json},"content":#{outcome.content.to_json},"is_error":#{outcome.error?}})
        end
        s << "]}"
      end
    end

    private def request_headers : HTTP::Headers
      HTTP::Headers{
        "x-api-key"         => @api_key,
        "anthropic-version" => ANTHROPIC_VERSION,
        "content-type"      => "application/json",
      }
    end

    private def error_message(body : String) : String
      JSON.parse(body)["error"]?.try(&.["message"]?).try(&.as_s) || "unknown error"
    rescue
      body
    end
  end
end
