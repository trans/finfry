require "http/client"
require "json"
require "./models"
require "./recurrence"

module Finfry
  # The seam between finfry and an AI service. Today it is backed by raw HTTPS
  # calls to the Claude Messages API (no SDK dependency — Crystal's stdlib
  # covers it); the rest of finfry only knows `extract` returns an `Intent`, so
  # the backing implementation can later be swapped for a multi-provider library
  # without touching the command layer.
  #
  # Request building and response parsing are split into pure methods so they can
  # be tested without network access.
  class AI
    API_URL           = "https://api.anthropic.com/v1/messages"
    ANTHROPIC_VERSION = "2023-06-01"
    DEFAULT_MODEL     = "claude-opus-4-8"
    MAX_TOKENS        = 1024

    # A single structured transaction, as extracted from free text. Shaped by the
    # JSON Schema we hand the model, so the model returns exactly these fields.
    struct Intent
      include JSON::Serializable

      property kind : String            # "expense" | "income" | "transfer"
      property amount : String          # positive decimal string, e.g. "50.00"
      property account : String         # categorization / destination account
      property counter_account : String # money / source account
      property date : String            # YYYY-MM-DD
      property description : String
      property recurrence : String # cadence name, or "none"

      def recurrence_or_nil : String?
        recurrence == "none" ? nil : recurrence
      end
    end

    def initialize(@api_key : String, @model : String = DEFAULT_MODEL)
    end

    # Build an AI client from the environment, or raise a friendly error.
    def self.from_env : AI
      key = ENV["ANTHROPIC_API_KEY"]?
      if key.nil? || key.empty?
        raise Error.new("ANTHROPIC_API_KEY is not set — export your Anthropic API key to use `finfry ai`")
      end
      new(key, ENV["FINFRY_MODEL"]? || DEFAULT_MODEL)
    end

    # Turn free text into a structured `Intent` by calling the AI service.
    def extract(text : String, accounts : Array(String), today : String, default_asset : String) : Intent
      body = build_body(text, accounts, today, default_asset)

      response =
        begin
          HTTP::Client.post(API_URL, headers: request_headers, body: body)
        rescue ex : IO::Error
          raise Error.new("could not reach the AI service: #{ex.message}")
        end

      unless response.success?
        raise Error.new("AI service error (HTTP #{response.status_code}): #{error_message(response.body)}")
      end

      parsed = JSON.parse(response.body) rescue nil
      if parsed && parsed["stop_reason"]?.try(&.as_s) == "refusal"
        raise Error.new("the AI declined to process that request")
      end

      AI.intent_from_response(response.body)
    end

    # --- pure: request building -----------------------------------------

    # The JSON request body sent to the Messages API. Public for testing.
    def build_body(text : String, accounts : Array(String), today : String, default_asset : String) : String
      prompt = system_prompt(accounts, today, default_asset)
      JSON.build do |json|
        json.object do
          json.field "model", @model
          json.field "max_tokens", MAX_TOKENS
          json.field "system", prompt
          json.field "messages" do
            json.array do
              json.object do
                json.field "role", "user"
                json.field "content", text
              end
            end
          end
          json.field "output_config" do
            json.object do
              json.field "format" do
                json.object do
                  json.field "type", "json_schema"
                  json.field "schema" { json.raw AI.intent_schema_json }
                end
              end
            end
          end
        end
      end
    end

    # The JSON Schema the model must fill in. "none" stands in for "no recurrence"
    # so the field can be a plain enum string rather than nullable.
    def self.intent_schema_json : String
      recurrences = (["none"] + Recurrence.names).to_json
      <<-JSON
      {
        "type": "object",
        "additionalProperties": false,
        "properties": {
          "kind": {"type": "string", "enum": ["expense", "income", "transfer"]},
          "amount": {"type": "string", "description": "Positive amount as a decimal string, e.g. 50.00"},
          "account": {"type": "string", "description": "Expenses:* for a spend, Income:* for income, or the destination account for a transfer"},
          "counter_account": {"type": "string", "description": "The asset/liability paid from or received into; the source account for a transfer"},
          "date": {"type": "string", "description": "ISO date YYYY-MM-DD"},
          "description": {"type": "string", "description": "Short human-readable description"},
          "recurrence": {"type": "string", "enum": #{recurrences}, "description": "Recurrence cadence, or \\"none\\""}
        },
        "required": ["kind", "amount", "account", "counter_account", "date", "description", "recurrence"]
      }
      JSON
    end

    # --- pure: response parsing -----------------------------------------

    # Extract the `Intent` from a raw Messages API response body. With structured
    # output the first text block is the JSON object matching our schema.
    def self.intent_from_response(body : String) : Intent
      json = JSON.parse(body)
      block = json["content"]?.try(&.as_a?).try(&.find { |b| b["type"]?.try(&.as_s) == "text" })
      raise Error.new("the AI returned no usable content") unless block
      Intent.from_json(block["text"].as_s)
    rescue ex : JSON::ParseException
      raise Error.new("could not parse the AI response: #{ex.message}")
    end

    # --- helpers --------------------------------------------------------

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

    private def system_prompt(accounts : Array(String), today : String, default_asset : String) : String
      account_list = accounts.empty? ? "(none yet)" : accounts.join("\n")
      <<-PROMPT
      You convert a short natural-language description of a personal finance event into one structured transaction for a double-entry ledger.

      Today's date is #{today}. Resolve relative dates ("yesterday", "last Friday") to an absolute YYYY-MM-DD; if no date is mentioned, use today.

      Accounts are hierarchical and colon-separated, by convention:
        Assets:*       money you have (e.g. #{default_asset}, Assets:Cash)
        Liabilities:*  money you owe (e.g. Liabilities:CreditCards:Visa)
        Income:*       where money comes from (e.g. Income:Salary)
        Expenses:*     where money goes (e.g. Expenses:Food:Coffee)

      Existing accounts — REUSE one whenever it reasonably fits; only invent a new account (following the same convention) when none fits:
      #{account_list}

      Rules:
      - kind "expense": account is the Expenses:* account; counter_account is the asset/liability it was paid from (default #{default_asset} if unstated).
      - kind "income": account is the Income:* account; counter_account is the asset it was received into (default #{default_asset}).
      - kind "transfer": account is the destination account; counter_account is the source account.
      - amount is always a positive decimal string.
      - recurrence is "none" unless the text clearly indicates a repeating charge (e.g. "monthly", "every year").
      PROMPT
    end
  end
end
