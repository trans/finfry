require "jargon"
require "levenshtein"
require "./store"
require "./money"
require "./recurrence"
require "./ai"

module Finfry
  # Wires the Jargon-defined CLI to the `Store` and renders output. Every entry
  # path (manual commands now, the AI layer later) funnels through `commit` and
  # `render`, so the ledger logic lives here rather than in the CLI handlers.
  class App
    def initialize(@store : Store = Store.new, @out : IO = STDOUT, @interactive : Bool = true)
    end

    def run(argv : Array(String)) : Nil
      cli.run(argv) { |result| dispatch(result) }
    rescue ex : Money::Error | Error
      abort_with(ex.message)
    rescue ex : IO::Error
      # Output pipe closed early (e.g. `finfry report | head`). Exit quietly like
      # a well-behaved Unix tool — but re-raise anything that isn't a broken pipe
      # (e.g. a real failure writing the ledger) so it still surfaces.
      raise ex unless ex.os_error == Errno::EPIPE
      exit 0
    end

    # All handler output flows through @out so the AI agent can capture a read
    # command's result. These shadow the top-level puts/print inside App.
    private def puts(*args) : Nil
      @out.puts(*args)
    end

    private def print(*args) : Nil
      @out.print(*args)
    end

    # Run a block with output captured to a string instead of printed.
    private def capture(&) : String
      previous = @out
      buffer = IO::Memory.new
      @out = buffer
      begin
        yield
      ensure
        @out = previous
      end
      buffer.to_s
    end

    # --- shared core (also used by the future AI/REPL layer) -------------

    # Validate, persist, and echo a transaction. The single commit path.
    def commit(date : String, description : String, postings : Array(Posting),
               recurrence : String? = nil) : Transaction
      validate_date!(date)
      if recurrence && !Recurrence.valid?(recurrence)
        raise Error.new("unknown recurrence #{recurrence.inspect} (one of: #{Recurrence.names.join(", ")})")
      end

      primary = postings.first
      label = description.empty? ? "#{Money.format(primary.amount)} #{primary.account}" : "#{description} (#{Money.format(primary.amount)})"

      @store.changeset(label, now) do
        enforce_account_policy!(postings)
        txn = @store.record(date, description, postings, recurrence)
        suffix = txn.recurrence ? " (#{txn.recurrence})" : ""
        puts "Recorded ##{txn.id}#{suffix}:"
        puts render(txn)
        txn
      end
    end

    # Human-readable rendering of a transaction's postings.
    def render(txn : Transaction) : String
      width = txn.postings.max_of { |p| p.account.size }
      txn.postings.map { |p|
        "    %-#{width}s  %12s" % {p.account, Money.format(p.amount)}
      }.join("\n")
    end

    # --- CLI definition --------------------------------------------------

    private def cli : Jargon::CLI
      cli = Jargon.new("finfry")

      cli.subcommand "ai", yaml: <<-YAML
        type: object
        description: Ask or instruct finfry in plain English (needs ANTHROPIC_API_KEY)
        positional: [text]
        properties:
          text: {type: string, description: "A question or instruction (or piped via stdin)"}
          "yes": {type: boolean, short: y, description: "Apply the proposed plan without confirming"}
        YAML

      cli.subcommand "spend", yaml: <<-YAML
        type: object
        description: Record an expense
        positional: [amount, account]
        properties:
          amount: {type: string, description: "Amount, e.g. 50 or 12.50"}
          account: {type: string, description: "Expense account, e.g. Expenses:Food:Coffee"}
          from: {type: string, short: f, description: "Account paid from", default: #{DEFAULT_ASSET_ACCOUNT}}
          memo: {type: string, short: m, description: "Note/memo", default: ""}
          date: {type: string, short: d, description: "Date YYYY-MM-DD (default today)"}
          recurrence: {type: string, short: r, description: "Recurs on a cadence", enum: [#{Recurrence.names.join(", ")}]}
        required: [amount, account]
        YAML

      cli.subcommand "earn", yaml: <<-YAML
        type: object
        description: Record income
        positional: [amount, account]
        properties:
          amount: {type: string, description: "Amount received"}
          account: {type: string, description: "Income account, e.g. Income:Salary"}
          to: {type: string, short: t, description: "Account received into", default: #{DEFAULT_ASSET_ACCOUNT}}
          memo: {type: string, short: m, description: "Note/memo", default: ""}
          date: {type: string, short: d, description: "Date YYYY-MM-DD (default today)"}
          recurrence: {type: string, short: r, description: "Recurs on a cadence", enum: [#{Recurrence.names.join(", ")}]}
        required: [amount, account]
        YAML

      cli.subcommand "transfer", yaml: <<-YAML
        type: object
        description: Move money between two accounts
        positional: [amount]
        properties:
          amount: {type: string, description: "Amount to move"}
          from: {type: string, short: f, description: "Source account"}
          to: {type: string, short: t, description: "Destination account"}
          memo: {type: string, short: m, description: "Note/memo", default: ""}
          date: {type: string, short: d, description: "Date YYYY-MM-DD (default today)"}
        required: [amount, from, to]
        YAML

      cli.subcommand "add", yaml: <<-YAML
        type: object
        description: Record a transaction with arbitrary postings (splits)
        positional: [posts]
        properties:
          posts: {type: array, description: "ACCOUNT AMOUNT pairs; a trailing lone ACCOUNT is inferred to balance"}
          memo: {type: string, short: m, description: "Note/memo", default: ""}
          date: {type: string, short: d, description: "Date YYYY-MM-DD (default today)"}
          recurrence: {type: string, short: r, description: "Recurs on a cadence", enum: [#{Recurrence.names.join(", ")}]}
        required: [posts]
        YAML

      cli.subcommand "register", yaml: <<-YAML
        type: object
        description: List transactions (the ledger register)
        properties:
          account: {type: string, short: a, description: "Only transactions touching this account subtree"}
          month: {type: string, short: m, description: "Only this month (YYYY-MM)"}
          limit: {type: integer, short: n, description: "Show only the most recent N"}
          since: {type: string, short: s, description: "On or after this date (YYYY-MM-DD)"}
          until: {type: string, short: u, description: "On or before this date (YYYY-MM-DD)"}
          min: {type: string, description: "Only transactions whose largest leg is at least this"}
          max: {type: string, description: "Only transactions whose largest leg is at most this"}
          match: {type: string, short: q, description: "Only transactions whose memo contains this text"}
        YAML

      cli.subcommand "balance", yaml: <<-YAML
        type: object
        description: Show account balances
        positional: [prefix]
        properties:
          prefix: {type: string, description: "Limit to this account subtree"}
        YAML

      report = Jargon.new("report")
      report.subcommand "income", yaml: <<-YAML
        type: object
        description: Income statement for a month
        properties:
          month: {type: string, short: m, description: "Month as YYYY-MM (default current)"}
        YAML
      report.subcommand "balance-sheet", yaml: <<-YAML
        type: object
        description: Balance sheet (Assets / Liabilities / Equity) with an integrity check
        properties:
          date: {type: string, short: d, description: "As of date YYYY-MM-DD (default today)"}
        YAML
      report.subcommand "daily", yaml: <<-YAML
        type: object
        description: Per-day cost of recurring items
        YAML
      report.subcommand "balance", yaml: <<-YAML
        type: object
        description: Show account balances
        positional: [prefix]
        properties:
          prefix: {type: string, description: "Limit to this account subtree"}
        YAML
      report.default_subcommand("income")
      cli.subcommand "report", report

      accounts = Jargon.new("accounts")
      accounts.subcommand "list", yaml: <<-YAML
        type: object
        description: List known accounts (declared + used)
        YAML
      accounts.subcommand "add", yaml: <<-YAML
        type: object
        description: Declare one or more accounts in the chart
        positional: [names]
        properties:
          names: {type: array, description: "Account names, e.g. Expenses:Food:Coffee"}
        required: [names]
        YAML
      accounts.subcommand "rm", yaml: <<-YAML
        type: object
        description: Remove an account from the chart
        positional: [name]
        properties:
          name: {type: string}
        required: [name]
        YAML
      accounts.subcommand "rename", yaml: <<-YAML
        type: object
        description: Rename an account everywhere (merges if the target exists)
        positional: [from, to]
        properties:
          from: {type: string}
          to: {type: string}
        required: [from, to]
        YAML
      accounts.subcommand "policy", yaml: <<-YAML
        type: object
        description: Show or set how unknown accounts are handled (strict/guard/off)
        positional: [mode]
        properties:
          mode: {type: string, enum: [strict, guard, off]}
        YAML
      accounts.subcommand "set", yaml: <<-YAML
        type: object
        description: Set a metadata key on an account (e.g. apr, limit, due-day, bank)
        positional: [account, key, value]
        properties:
          account: {type: string}
          key: {type: string}
          value: {type: string}
        required: [account, key, value]
        YAML
      accounts.subcommand "unset", yaml: <<-YAML
        type: object
        description: Remove a metadata key from an account
        positional: [account, key]
        properties:
          account: {type: string}
          key: {type: string}
        required: [account, key]
        YAML
      accounts.subcommand "info", yaml: <<-YAML
        type: object
        description: Show an account's balance and metadata
        positional: [account]
        properties:
          account: {type: string}
        required: [account]
        YAML
      accounts.default_subcommand("list")
      cli.subcommand "accounts", accounts

      cli.subcommand "undo", yaml: <<-YAML
        type: object
        description: Undo the last change (removes it); with an id, post a reversing entry
        positional: [id]
        properties:
          id: {type: integer, description: "Change id to reverse (see 'history')"}
        YAML

      cli.subcommand "redo", yaml: <<-YAML
        type: object
        description: Redo the change most recently removed by undo
        YAML

      cli.subcommand "history", yaml: <<-YAML
        type: object
        description: Show the change history
        properties:
          limit: {type: integer, short: n, description: "Show only the most recent N"}
        YAML

      cli.subcommand "init", yaml: <<-YAML
        type: object
        description: Create a finfry book (ledger) in a directory (current one by default)
        positional: [path]
        properties:
          path: {type: string, description: "Directory for the book (defaults to the current directory)"}
          "no-mcp": {type: boolean, description: "Skip writing a .mcp.json for AI/harness access"}
        YAML

      cli.subcommand "path", yaml: <<-YAML
        type: object
        description: Print the path to the active ledger file
        YAML

      cli.subcommand "version", yaml: <<-YAML
        type: object
        description: Print the finfry version
        YAML

      cli.subcommand "mcp", yaml: <<-YAML
        type: object
        description: Run as an MCP server (stdio) for use inside an agent harness
        YAML

      cli.subcommand "delete", yaml: <<-YAML
        type: object
        description: Delete a transaction by id
        positional: [id]
        properties:
          id: {type: integer, description: "Transaction id (see 'list')"}
        required: [id]
        YAML

      budget = Jargon.new("budget")
      budget.subcommand "set", yaml: <<-YAML
        type: object
        description: Set a monthly budget for an account
        positional: [account, amount]
        properties:
          account: {type: string, description: "Expense account, e.g. Expenses:Food"}
          amount: {type: string, description: "Monthly limit"}
        required: [account, amount]
        YAML
      budget.subcommand "list", yaml: <<-YAML
        type: object
        description: Show budgets vs. this month's spending
        properties:
          month: {type: string, short: m, description: "Month as YYYY-MM (default current)"}
        YAML
      budget.subcommand "rm", yaml: <<-YAML
        type: object
        description: Remove an account's budget
        positional: [account]
        properties:
          account: {type: string}
        required: [account]
        YAML
      cli.subcommand "budget", budget

      recurring = Jargon.new("recurring")
      recurring.subcommand "add", yaml: <<-YAML
        type: object
        description: Define a recurring rule (generates due entries to approve)
        positional: [amount, account]
        properties:
          amount: {type: string, description: "Amount per occurrence"}
          account: {type: string, description: "Expenses:* (spend), Income:* (income), or the destination (transfer)"}
          counter: {type: string, short: c, description: "The other account: paid-from / received-into / transfer source (default #{DEFAULT_ASSET_ACCOUNT})"}
          kind: {type: string, enum: [expense, income, transfer], description: "Default expense"}
          every: {type: string, short: e, enum: [#{Recurrence.names.join(", ")}], description: "Cadence"}
          start: {type: string, short: s, description: "First occurrence date YYYY-MM-DD (default today)"}
          memo: {type: string, short: m, description: "Note/memo", default: ""}
        required: [amount, account, every]
        YAML
      recurring.subcommand "interest", yaml: <<-YAML
        type: object
        description: Add a computed interest rule (amount = card APR x balance owed, each cycle)
        positional: [card]
        properties:
          card: {type: string, description: "The credit-card / liability account"}
          account: {type: string, short: a, description: "Interest expense account (default Expenses:Interest)"}
          every: {type: string, short: e, enum: [#{Recurrence.names.join(", ")}], description: "Cadence (default monthly)"}
          apr: {type: string, short: r, description: "Set the card's APR %% (else uses its existing apr metadata)"}
          start: {type: string, short: s, description: "First occurrence YYYY-MM-DD (default today)"}
          memo: {type: string, short: m, description: "Note (default 'Interest on <card>')"}
        required: [card]
        YAML
      recurring.subcommand "list", yaml: <<-YAML
        type: object
        description: List recurring rules
        YAML
      recurring.subcommand "off", yaml: <<-YAML
        type: object
        description: Turn off a recurring rule (stops generating new occurrences)
        positional: [id]
        properties:
          id: {type: integer, description: "Rule id (see 'recurring list')"}
        required: [id]
        YAML
      recurring.default_subcommand("list")
      cli.subcommand "recurring", recurring

      due = Jargon.new("due")
      due.subcommand "list", yaml: <<-YAML
        type: object
        description: Show the due queue (occurrences awaiting review)
        YAML
      due.subcommand "ok", yaml: <<-YAML
        type: object
        description: Stage entries to post (ids, or 'all')
        positional: [ids]
        properties:
          ids: {type: array, description: "Entry ids, or 'all'"}
        required: [ids]
        YAML
      due.subcommand "skip", yaml: <<-YAML
        type: object
        description: Stage entries to drop (ids, or 'all')
        positional: [ids]
        properties:
          ids: {type: array, description: "Entry ids, or 'all'"}
        required: [ids]
        YAML
      due.subcommand "reset", yaml: <<-YAML
        type: object
        description: Clear staged decisions back to pending (ids, or 'all')
        positional: [ids]
        properties:
          ids: {type: array, description: "Entry ids, or 'all'"}
        required: [ids]
        YAML
      due.subcommand "edit", yaml: <<-YAML
        type: object
        description: Adjust a due entry before posting (marks it ok)
        positional: [id]
        properties:
          id: {type: integer}
          amount: {type: string, short: a, description: "New amount"}
          date: {type: string, short: d, description: "New date YYYY-MM-DD"}
          memo: {type: string, short: m, description: "New note/memo"}
        required: [id]
        YAML
      due.subcommand "post", yaml: <<-YAML
        type: object
        description: Apply staged decisions — post the ok'd, drop the skipped
        YAML
      due.default_subcommand("list")
      cli.subcommand "due", due

      # Account-first by design: the account is common to every form, so it
      # always comes right after `reconcile`. An optional action follows, and
      # each action owns its trailing argument — clear/unclear take ids,
      # balance/commit take the statement balance. Keeping the slot after the
      # account a strict enum means a forgotten verb (`reconcile A 1 2`) fails
      # loudly instead of misreading "1" as a balance.
      cli.subcommand "reconcile", yaml: <<-YAML
        type: object
        description: Reconcile an account against a statement (stage with clear/unclear, check with balance, then commit)
        positional: [account, action, args]
        properties:
          account: {type: string, description: "The account to reconcile"}
          action: {type: string, enum: [clear, unclear, balance, commit, history], description: "Stage (clear/unclear <ids>), check (balance <amount>), finalize (commit <amount>), or list past reconciliations (history)"}
          args: {type: array, description: "Transaction ids for clear/unclear (or 'all'); the statement balance for balance/commit"}
          adjust: {type: boolean, description: "With commit: post any small residual to Expenses:ShortsAndOverages so it balances"}
        required: [account]
        YAML

      cli
    end

    # --- dispatch --------------------------------------------------------

    private def dispatch(result : Jargon::Result) : Nil
      case result.subcommand
      when "ai"                   then cmd_ai(result)
      when "spend"                then cmd_spend(result)
      when "earn"                 then cmd_earn(result)
      when "transfer"             then cmd_transfer(result)
      when "add"                  then cmd_add(result)
      when "register"             then cmd_register(result)
      when "balance"              then cmd_balance(result)
      when "report income"        then cmd_report(result)
      when "report balance-sheet" then cmd_balancesheet(result)
      when "report daily"         then cmd_daily(result)
      when "report balance"       then cmd_balance(result)
      when "accounts list"        then cmd_accounts_list(result)
      when "accounts add"         then cmd_accounts_add(result)
      when "accounts rm"          then cmd_accounts_rm(result)
      when "accounts rename"      then cmd_accounts_rename(result)
      when "accounts policy"      then cmd_accounts_policy(result)
      when "accounts set"         then cmd_accounts_set(result)
      when "accounts unset"       then cmd_accounts_unset(result)
      when "accounts info"        then cmd_accounts_info(result)
      when "undo"                 then cmd_undo(result)
      when "redo"                 then cmd_redo(result)
      when "history"              then cmd_history(result)
      when "init"                 then cmd_init(result)
      when "path"                 then cmd_path(result)
      when "version"              then cmd_version(result)
      when "mcp"                  then cmd_mcp(result)
      when "delete"               then cmd_delete(result)
      when "recurring add"        then cmd_recurring_add(result)
      when "recurring interest"   then cmd_recurring_interest(result)
      when "recurring list"       then cmd_recurring_list(result)
      when "recurring off"        then cmd_recurring_off(result)
      when "due list"             then cmd_due_list(result)
      when "due ok"               then cmd_due_stage(result, "ok")
      when "due skip"             then cmd_due_stage(result, "skip")
      when "due reset"            then cmd_due_stage(result, "pending")
      when "due edit"             then cmd_due_edit(result)
      when "due post"             then cmd_due_post(result)
      when "reconcile"            then cmd_reconcile(result)
      when "budget set"           then cmd_budget_set(result)
      when "budget list"          then cmd_budget_list(result)
      when "budget rm"            then cmd_budget_rm(result)
      else
        puts cli.help
      end
    end

    # --- entry commands --------------------------------------------------

    private def cmd_spend(r : Jargon::Result) : Nil
      amount = Money.parse(r["amount"].as_s)
      from = r["from"]?.try(&.as_s) || DEFAULT_ASSET_ACCOUNT
      postings = Finfry.postings_for("expense", amount, r["account"].as_s, from)
      commit(date_of(r), desc_of(r), postings, recurrence_of(r))
    end

    private def cmd_earn(r : Jargon::Result) : Nil
      amount = Money.parse(r["amount"].as_s)
      to = r["to"]?.try(&.as_s) || DEFAULT_ASSET_ACCOUNT
      postings = Finfry.postings_for("income", amount, r["account"].as_s, to)
      commit(date_of(r), desc_of(r), postings, recurrence_of(r))
    end

    private def cmd_transfer(r : Jargon::Result) : Nil
      amount = Money.parse(r["amount"].as_s)
      postings = Finfry.postings_for("transfer", amount, r["to"].as_s, r["from"].as_s)
      commit(date_of(r), desc_of(r), postings, recurrence_of(r))
    end

    private def cmd_ai(r : Jargon::Result) : Nil
      text = r["text"]?.try(&.as_s) || ""
      piped = false
      if text.strip.empty?
        text = STDIN.gets_to_end.strip
        piped = true
      end
      raise Error.new("no request given") if text.empty?

      specs = agent_tools_spec
      by_name = specs.to_h { |s| {s.name, s} }
      tools = specs.map { |s| AI::ToolDef.new(s.name, s.description, s.schema) }
      plan = [] of {String, JSON::Any}

      answer = AI.from_env.converse(text, system: agent_system_prompt, tools: tools) do |call|
        run_tool(call, by_name, plan)
      end

      puts answer unless answer.strip.empty?
      return if plan.empty?

      puts ""
      puts "Plan:"
      plan.each { |(subcommand, input)| puts "  #{describe_write(subcommand, input)}" }

      unless r["yes"]?.try(&.as_bool)
        if piped || !STDIN.tty?
          raise Error.new("re-run with --yes to apply (can't prompt when input is piped)")
        end
        return puts("Not applied.") unless confirm?("Apply this plan?")
      end

      flat = text.gsub('\n', ' ')
      @store.changeset("ai: #{flat.size > 60 ? "#{flat[0, 57]}..." : flat}", now) do
        plan.each { |(subcommand, input)| dispatch(Jargon::Result.new(input, subcommand: subcommand)) }
      end
    end

    # Run one tool call: read tools execute now (captured output is returned to
    # the model); write tools are queued into `plan` for the user to approve.
    private def run_tool(call : AI::ToolCall, by_name : Hash(String, AgentTool), plan : Array({String, JSON::Any})) : AI::ToolOutcome
      spec = by_name[call.name]?
      return AI::ToolOutcome.new("unknown tool '#{call.name}'", error: true) unless spec

      if spec.write
        plan << {spec.subcommand, call.input}
        AI::ToolOutcome.new("Queued for the user's approval.")
      else
        output = capture { dispatch(Jargon::Result.new(call.input, subcommand: spec.subcommand)) }
        AI::ToolOutcome.new(output.blank? ? "(no output)" : output)
      end
    rescue ex : Money::Error | Error
      AI::ToolOutcome.new("error: #{ex.message}", error: true)
    end

    # A readable one-line preview of a queued write.
    private def describe_write(subcommand : String, input : JSON::Any) : String
      args = input.as_h.compact_map do |key, value|
        next if value.raw.nil?
        rendered = value.as_a?.try(&.join(",")) || value.to_s
        "#{key}=#{rendered}"
      end
      "#{subcommand} #{args.join(" ")}".rstrip
    end

    # Enforce the unknown-account policy before recording. Strict rejects;
    # guard prompts and declares on confirmation; off does nothing.
    private def enforce_account_policy!(postings : Array(Posting)) : Nil
      return if @store.account_policy == "off"
      unknown = postings.map(&.account).uniq.reject { |a| @store.account_known?(a) }
      return if unknown.empty?

      if @store.account_policy == "strict" || !@interactive
        raise Error.new(unknown_accounts_message(unknown))
      else
        unknown.each do |account|
          hint = suggest_account(account)
          question = hint ? "New account '#{account}' (did you mean '#{hint}'?). Create it?" : "New account '#{account}'. Create it?"
          raise Error.new("cancelled — '#{account}' not recorded") unless confirm?(question)
          @store.declare_account(account)
        end
      end
    end

    private def unknown_accounts_message(unknown : Array(String)) : String
      lines = unknown.map do |account|
        hint = suggest_account(account)
        "  unknown account '#{account}'#{hint ? " (did you mean '#{hint}'?)" : ""}"
      end
      "#{lines.join("\n")}\n  declare it:  finfry accounts add #{unknown.join(" ")}"
    end

    # Closest known account within a small edit distance, advisory only.
    private def suggest_account(name : String) : String?
      known = @store.known_accounts
      return nil if known.empty?
      best = known.min_by { |candidate| Levenshtein.distance(name, candidate) }
      Levenshtein.distance(name, best) <= name.size // 3 + 1 ? best : nil
    end

    private def confirm?(question : String) : Bool
      print "#{question} [y/N] "
      STDOUT.flush
      answer = STDIN.gets
      !answer.nil? && answer.strip.downcase.in?("y", "yes")
    end

    private def cmd_add(r : Jargon::Result) : Nil
      tokens = r["posts"].as_a.map(&.as_s)
      commit(date_of(r), desc_of(r), parse_postings(tokens), recurrence_of(r))
    end

    # ACCOUNT AMOUNT pairs, with an optional final lone ACCOUNT whose amount is
    # inferred so the transaction balances.
    private def parse_postings(tokens : Array(String)) : Array(Posting)
      raise Error.new("need at least one ACCOUNT AMOUNT pair") if tokens.size < 2

      omitted = tokens.size.odd? ? tokens.last : nil
      pairs = omitted ? tokens[0...-1] : tokens

      postings = [] of Posting
      i = 0
      while i < pairs.size
        postings << Posting.new(pairs[i], Money.parse(pairs[i + 1]))
        i += 2
      end
      if account = omitted
        postings << Posting.new(account, -postings.sum(&.amount))
      end
      postings
    end

    # --- reports ---------------------------------------------------------

    private def cmd_register(r : Jargon::Result) : Nil
      txns = @store.transactions
      account = r["account"]?.try(&.as_s)

      # When filtered to an account, precompute the true running balance at each
      # of its transactions (over full history, in date order) so the column
      # stays accurate even when later filters/limit show only a window.
      running = nil
      if account
        running = {} of Int32 => Int64
        bal = 0_i64
        @store.transactions.select(&.touches?(account)).sort_by { |t| {t.date, t.id} }.each do |t|
          bal += account_leg(t, account)
          running[t.id] = display_cents(account, bal)
        end
        txns = txns.select(&.touches?(account))
      end
      if month = r["month"]?.try(&.as_s)
        txns = txns.select(&.in_month?(month))
      end
      if since = r["since"]?.try(&.as_s)
        txns = txns.select { |t| t.date >= since }
      end
      if before = r["until"]?.try(&.as_s)
        txns = txns.select { |t| t.date <= before }
      end
      if min = r["min"]?.try(&.as_s)
        floor = Money.parse(min)
        txns = txns.select { |t| txn_magnitude(t) >= floor }
      end
      if max = r["max"]?.try(&.as_s)
        ceil = Money.parse(max)
        txns = txns.select { |t| txn_magnitude(t) <= ceil }
      end
      if q = r["match"]?.try(&.as_s)
        needle = q.downcase
        txns = txns.select { |t| t.description.downcase.includes?(needle) }
      end
      txns = txns.sort_by { |t| {t.date, t.id} }
      if limit = r["limit"]?.try(&.as_i)
        txns = txns.last(limit)
      end

      if txns.empty?
        puts "No transactions found."
        return
      end

      # Account view: a compact one-line-per-transaction register with the
      # account's own movement and a running balance. Unfiltered view: full
      # postings per transaction.
      if account && (run = running)
        txns.each do |t|
          memo = t.description
          memo += " (#{t.recurrence})" if t.recurrence
          memo = "#{memo[0, 27]}…" if memo.size > 28
          puts "#%-4d %s  %-28s %13s  %13s" % {
            t.id, t.date, memo,
            Money.format(display_cents(account, account_leg(t, account))), Money.format(run[t.id]),
          }
        end
      else
        txns.each do |t|
          header = "##{t.id}  #{t.date}"
          header += "  #{t.description}" unless t.description.empty?
          header += "  (#{t.recurrence})" if t.recurrence
          puts header
          puts render(t)
        end
      end
    end

    # The signed movement of `account` (its subtree) within one transaction.
    private def account_leg(txn : Transaction, account : String) : Int64
      txn.postings.sum(0_i64) { |p| Finfry.in_subtree?(p.account, account) ? p.amount : 0_i64 }
    end

    # Route the account-first reconcile command. `reconcile <account>` shows
    # status; `clear`/`unclear <ids>` stage the cleared tier; `balance <amount>`
    # checks against the statement; `commit <amount>` finalizes. The AI hits the
    # default branch and passes the statement as the named `statement` property.
    private def cmd_reconcile(r : Jargon::Result) : Nil
      account = r["account"].as_s
      args = r["args"]?.try(&.as_a.map(&.to_s)) || [] of String
      case r["action"]?.try(&.as_s)
      when "clear"   then cmd_reconcile_mark(account, args, true)
      when "unclear" then cmd_reconcile_mark(account, args, false)
      when "balance" then cmd_reconcile_status(account, args.first?)
      when "commit"  then cmd_reconcile_commit(account, args.first?, r["adjust"]?.try(&.as_bool) || false)
      when "history" then cmd_reconcile_history(account)
      else                cmd_reconcile_status(account, r["statement"]?.try(&.as_s))
      end
    end

    # The reconciliation view: the working list (every not-yet-reconciled
    # transaction touching the account, each marked `*` if staged-cleared), the
    # cleared balance (committed + staged — what should match a statement), the
    # full ledger balance, and — if -s is given — whether they agree.
    private def cmd_reconcile_status(account : String, statement : String?) : Nil
      cleared_raw = @store.reconciled_balance(account) + @store.cleared_balance(account)
      cleared = display_cents(account, cleared_raw)
      ledger = display_cents(account, @store.balances[account]? || 0_i64)
      staged = @store.cleared_ids(account).to_set
      working = reconcile_working_list(account)

      puts "Reconcile #{account}"
      puts "  cleared balance:  %14s" % Money.format(cleared)
      puts "  ledger balance:   %14s" % Money.format(ledger)

      if last = @store.last_reconciliation(account)
        puts "  last reconciled:  %14s on %s" % {Money.format(last.statement), last.date}
      end

      unless working.empty?
        puts "  to reconcile (#{working.size}, #{staged.size} cleared):"
        working.each do |t|
          mark = staged.includes?(t.id) ? "*" : " "
          amount = display_cents(account, t.postings.sum(0_i64) { |p| p.account == account ? p.amount : 0_i64 })
          memo = t.description.empty? ? "" : "  #{t.description}"
          puts "  #{mark} ##{t.id}  #{t.date}  %12s%s" % {Money.format(amount), memo}
        end
      end

      if statement
        diff = Money.parse(statement) - cleared
        puts "  statement:        %14s" % Money.format(Money.parse(statement))
        if diff.zero?
          puts "  ✓ cleared balance matches — `reconcile #{account} commit #{statement}` to finalize"
        else
          puts "  ⚠ off by %s — clear/unclear until the cleared balance matches the statement" % Money.format(diff)
        end
      end
    end

    # Finalize: every staged-cleared transaction is locked into the committed
    # tier, but only if the cleared balance matches the statement — so you can't
    # reconcile to a wrong number. Requires -s.
    # Where --adjust books a small unexplained reconciliation residual — the
    # classic "cash over and short" account. Big or explainable differences
    # should be entered manually to their real accounts instead.
    SHORT_OVER_ACCOUNT = "Expenses:ShortsAndOverages"

    private def cmd_reconcile_commit(account : String, statement : String?, adjust : Bool) : Nil
      unless statement
        puts "commit needs the statement balance: reconcile #{account} commit <balance>"
        return
      end

      target = Money.parse(statement)
      diff = target - display_cents(account, @store.reconciled_balance(account) + @store.cleared_balance(account))

      unless diff.zero?
        unless adjust
          puts "Can't commit — cleared balance is %s but the statement is %s (off by %s)." % {Money.format(target - diff), Money.format(target), Money.format(diff)}
          puts "Clear/unclear until they match (or `commit #{statement} --adjust` to book the residual to #{SHORT_OVER_ACCOUNT})."
          return
        end
        post_reconcile_adjustment(account, diff)
      end

      if @store.cleared_ids(account).empty?
        puts "Nothing staged to commit — clear the transactions on the statement first."
        return
      end

      locked = @store.reconcile!(account, target, today)
      puts "✓ Reconciled #{account} to #{Money.format(target)} as of #{today} (#{locked} transaction(s) locked)."
    end

    # Post the residual as a normal, balanced, undoable transaction: one leg
    # closes the gap on the reconciled account, the other lands in the
    # short-and-over expense account. It's staged cleared so the very next
    # reconcile! locks it in along with everything else.
    private def post_reconcile_adjustment(account : String, diff : Int64) : Nil
      @store.declare_account(SHORT_OVER_ACCOUNT) unless @store.account_known?(SHORT_OVER_ACCOUNT)
      raw = display_cents(account, diff) # display_cents is its own inverse (a conditional negate)
      postings = [Posting.new(account, raw), Posting.new(SHORT_OVER_ACCOUNT, -raw)]
      txn = commit(today, "Reconciliation adjustment (#{account})", postings)
      @store.set_cleared(account, [txn.id], true)
    end

    # List an account's finalized reconciliations — the audit trail of what was
    # balanced against which statement, and when.
    private def cmd_reconcile_history(account : String) : Nil
      recs = @store.reconciliations(account)
      if recs.empty?
        puts "No reconciliations for #{account} yet."
        return
      end
      puts "Reconciliations for #{account}"
      recs.each do |rec|
        n = rec.transaction_ids.size
        puts "  %s  %14s  (%d txn%s)" % {rec.date, Money.format(rec.statement), n, n == 1 ? "" : "s"}
      end
    end

    # Mark (clear:true) or unmark (clear:false) transactions in the staged tier.
    # `tokens` is a list of transaction ids or "all" (all not-yet-reconciled
    # when clearing, all currently-staged when unclearing).
    private def cmd_reconcile_mark(account : String, tokens : Array(String), clear : Bool) : Nil
      ids =
        if tokens.includes?("all")
          clear ? reconcile_working_list(account).map(&.id) : @store.cleared_ids(account).dup
        else
          tokens.compact_map(&.to_i?)
        end

      if ids.empty?
        puts clear ? "Nothing to clear." : "Nothing to unclear."
        return
      end

      changed = @store.set_cleared(account, ids, clear)
      verb = clear ? "Cleared" : "Uncleared"
      puts "#{verb} #{changed} transaction(s) for #{account}."
    end

    # The working list: transactions with a posting directly on `account`
    # (exact, not subtree) that aren't yet reconciled (committed), oldest first.
    # Staged-cleared ones stay here so they remain visible and un-clearable.
    private def reconcile_working_list(account : String) : Array(Transaction)
      done = @store.reconciled_ids(account).to_set
      @store.transactions
        .select { |t| !done.includes?(t.id) && t.postings.any? { |p| p.account == account } }
        .sort_by { |t| {t.date, t.id} }
    end

    private def cmd_balance(r : Jargon::Result) : Nil
      prefix = r["prefix"]?.try(&.as_s)
      balances = @store.balances(prefix)

      if balances.empty?
        puts "No balances to show."
        return
      end

      width = balances.keys.max_of(&.size)
      balances.to_a.sort_by { |(account, _)| account }.each do |(account, cents)|
        puts "%-#{width}s  %14s" % {account, Money.format(display_cents(account, cents))}
      end
    end

    private def cmd_report(r : Jargon::Result) : Nil
      month = r["month"]?.try(&.as_s) || current_month
      validate_month!(month)
      txns = @store.transactions.select(&.in_month?(month))

      if txns.empty?
        puts "No transactions for #{month}."
        return
      end

      income = Hash(String, Int64).new(0_i64)
      expenses = Hash(String, Int64).new(0_i64)
      txns.each do |t|
        t.postings.each do |p|
          income[p.account] += p.amount if p.account.starts_with?("Income")
          expenses[p.account] += p.amount if p.account.starts_with?("Expenses")
        end
      end

      total_income = -income.values.sum(0_i64) # Income is credit-normal
      total_expenses = expenses.values.sum(0_i64)

      puts "Income statement for #{month}"
      puts "─" * 40
      puts "Income"
      print_account_lines(income, flip: true)
      puts "%-26s  %12s" % {"  Total income", Money.format(total_income)}
      puts "Expenses"
      print_account_lines(expenses, flip: false)
      puts "%-26s  %12s" % {"  Total expenses", Money.format(total_expenses)}
      puts "─" * 40
      puts "%-26s  %12s" % {"Net", Money.format(total_income - total_expenses)}
    end

    private def print_account_lines(accounts : Hash(String, Int64), flip : Bool) : Nil
      accounts.to_a.sort_by { |(_, cents)| flip ? cents : -cents }.each do |(account, cents)|
        amount = flip ? -cents : cents
        puts "  %-24s  %12s" % {account, Money.format(amount)}
      end
    end

    private def cmd_balancesheet(r : Jargon::Result) : Nil
      as_of = r["date"]?.try(&.as_s)
      validate_date!(as_of) if as_of
      sheet = Finfry.balance_sheet(@store.balances(up_to: as_of))

      puts "Balance sheet — #{as_of || today}"
      bs_section("Assets", sheet.assets, sheet.total_assets)
      bs_section("Liabilities", sheet.liabilities, sheet.total_liabilities)

      puts "Equity"
      sheet.equity.each { |(account, value)| puts "  %-30s  %12s" % {account, Money.format(value)} }
      puts "  %-30s  %12s" % {"Net income (Income − Expenses)", Money.format(sheet.net_income)}
      puts "  %-30s  %12s" % {"Total equity", Money.format(sheet.total_equity)}

      puts "─" * 48
      rhs = sheet.total_liabilities + sheet.total_equity
      if sheet.balanced?
        puts "Assets = Liabilities + Equity   ✓  (#{Money.format(sheet.total_assets)} = #{Money.format(rhs)})"
      else
        puts "Assets = Liabilities + Equity   ⚠  off by #{Money.format(sheet.discrepancy)} (ledger may be tampered)"
      end
    end

    private def bs_section(label : String, entries : Array({String, Int64}), total : Int64) : Nil
      puts label
      entries.each { |(account, value)| puts "  %-30s  %12s" % {account, Money.format(value)} }
      puts "  %-30s  %12s" % {"Total #{label.downcase}", Money.format(total)}
    end

    private def cmd_daily(r : Jargon::Result) : Nil
      items = Finfry.recurring_items(@store.transactions)
      if items.empty?
        puts "No recurring items. Tag one with -r when you spend or earn (e.g. -r monthly)."
        return
      end

      width = items.max_of { |i| i.label.size }
      expenses = items.select(&.expense?)
      incomes = items.select(&.income?)

      unless expenses.empty?
        puts "Recurring expenses"
        expenses.each { |i| puts daily_line(i, width) }
        puts daily_total("Total", expenses.sum(&.per_day), width)
      end

      unless incomes.empty?
        puts "" unless expenses.empty?
        puts "Recurring income"
        incomes.each { |i| puts daily_line(i, width) }
        puts daily_total("Total", incomes.sum(&.per_day), width)
      end

      if !expenses.empty? && !incomes.empty?
        net = incomes.sum(&.per_day) - expenses.sum(&.per_day)
        puts daily_total("Net", net, width)
      end
    end

    private def daily_line(item : RecurringItem, width : Int32) : String
      "  %-#{width}s  %-9s  %12s  →  %9s/day" % {
        item.label, item.recurrence, Money.format(item.amount), fmt(item.per_day),
      }
    end

    private def daily_total(label : String, per_day : Float64, width : Int32) : String
      "  %-#{width}s  %-9s  %12s     %9s/day  (%s/mo, %s/yr)" % {
        label, "", "", fmt(per_day), fmt(per_day * Recurrence::AVG_MONTH), fmt(per_day * Recurrence::AVG_YEAR),
      }
    end

    private def fmt(cents : Float64) : String
      Money.format(cents.round.to_i64)
    end

    private def cmd_init(r : Jargon::Result) : Nil
      target = r["path"]?.try(&.as_s) || Dir.current
      book = File.expand_path(File.join(target, Store::BOOK_FILE))
      raise Error.new("already a finfry book: #{book}") if File.exists?(book)

      Store.new(book).save
      puts "Initialized finfry book at #{book}"

      write_mcp_config(File.dirname(book), book) unless r["no-mcp"]?.try(&.as_bool)
    end

    # Write (or merge into) a .mcp.json next to the book so any MCP client opened
    # in this directory gets a `finfry` server pinned to this book — no manual
    # `claude mcp add` per book. Other servers in an existing file are preserved.
    private def write_mcp_config(dir : String, book : String) : Nil
      path = File.join(dir, ".mcp.json")
      existing = File.exists?(path) ? File.read(path) : nil
      File.write(path, App.merge_mcp_config(existing, book) + "\n")
      puts "Wrote #{path} (finfry MCP server pinned to this book)"
    end

    # Merge a `finfry` MCP server (pinned to `book` via FINFRY_DATA) into an
    # existing .mcp.json document (or a fresh one), preserving any other servers.
    def self.merge_mcp_config(existing : String?, book : String) : String
      root = existing ? JSON.parse(existing).as_h.dup : {} of String => JSON::Any
      servers = root["mcpServers"]?.try(&.as_h).try(&.dup) || {} of String => JSON::Any
      servers["finfry"] = JSON.parse(%({"command":"finfry","args":["mcp"],"env":{"FINFRY_DATA":#{book.to_json}}}))
      root["mcpServers"] = JSON::Any.new(servers)
      JSON::Any.new(root).to_pretty_json
    end

    private def cmd_path(r : Jargon::Result) : Nil
      puts @store.path
    end

    private def cmd_version(r : Jargon::Result) : Nil
      puts "finfry #{Finfry::VERSION}"
    end

    private def cmd_mcp(r : Jargon::Result) : Nil
      MCP.new(@store).run
    end

    private def cmd_undo(r : Jargon::Result) : Nil
      if id = r["id"]?.try(&.as_i)
        if cs = @store.reverse(id, now, today)
          puts "Reversed ##{id} — posted correcting entry ##{cs.id}"
        else
          raise Error.new("no change ##{id} (see 'history')")
        end
      elsif cs = @store.undo_last
        puts "Undid ##{cs.id}: #{cs.summary}"
      else
        puts "Nothing to undo."
      end
    end

    private def cmd_redo(r : Jargon::Result) : Nil
      if cs = @store.redo_last
        puts "Redid ##{cs.id}: #{cs.summary}"
      else
        puts "Nothing to redo."
      end
    end

    private def cmd_history(r : Jargon::Result) : Nil
      sets = @store.changesets.reverse
      if limit = r["limit"]?.try(&.as_i)
        sets = sets.first(limit)
      end
      if sets.empty?
        puts "No history yet."
        return
      end
      sets.each do |cs|
        flag = !cs.reversal? && @store.reversed?(cs.id) ? "  (reversed)" : ""
        puts "##{cs.id}  #{cs.at}  #{cs.summary}#{flag}"
      end
    end

    private def cmd_accounts_list(r : Jargon::Result) : Nil
      known = @store.known_accounts
      if known.empty?
        puts "No accounts yet."
        return
      end
      used = @store.used_accounts.to_set
      known.each do |a|
        marker = used.includes?(a) ? "" : "  (unused)"
        puts "#{a}#{marker}#{meta_suffix(a)}"
      end
    end

    private def cmd_accounts_set(r : Jargon::Result) : Nil
      account = r["account"].as_s
      key = r["key"].as_s
      value = r["value"].as_s
      @store.set_account_meta(account, key, value)
      puts "#{account}: #{key} = #{value}"
    end

    private def cmd_accounts_unset(r : Jargon::Result) : Nil
      account = r["account"].as_s
      key = r["key"].as_s
      if @store.unset_account_meta(account, key)
        puts "Removed #{key} from #{account}"
      else
        raise Error.new("#{account} has no metadata key '#{key}'")
      end
    end

    private def cmd_accounts_info(r : Jargon::Result) : Nil
      account = r["account"].as_s
      balance = @store.balances[account]? || 0_i64
      puts account
      puts "  balance: #{Money.format(display_cents(account, balance))}"
      meta = @store.account_meta(account)
      meta.to_a.sort_by { |(k, _)| k }.each { |(k, v)| puts "  #{k}: #{v}" }
    end

    # " {key=value, ...}" for an account with metadata, else "".
    private def meta_suffix(account : String) : String
      meta = @store.account_meta(account)
      return "" if meta.empty?
      "  {#{meta.to_a.sort_by { |(k, _)| k }.map { |(k, v)| "#{k}=#{v}" }.join(", ")}}"
    end

    private def cmd_accounts_add(r : Jargon::Result) : Nil
      r["names"].as_a.map(&.as_s).each do |name|
        puts(@store.declare_account(name) ? "Added #{name}" : "#{name} already declared")
      end
    end

    private def cmd_accounts_rm(r : Jargon::Result) : Nil
      name = r["name"].as_s
      if @store.undeclare_account(name)
        msg = "Removed #{name} from the chart"
        msg += " (still referenced by existing transactions)" if @store.used_accounts.includes?(name)
        puts msg
      else
        raise Error.new("#{name} is not in the chart")
      end
    end

    private def cmd_accounts_rename(r : Jargon::Result) : Nil
      from = r["from"].as_s
      to = r["to"].as_s
      count = @store.rename_account(from, to)
      puts "Renamed #{from} → #{to} (#{count} posting#{count == 1 ? "" : "s"} rewritten)"
    end

    private def cmd_accounts_policy(r : Jargon::Result) : Nil
      if mode = r["mode"]?.try(&.as_s)
        @store.set_account_policy(mode)
        puts "Account policy set to #{mode}"
      else
        puts "Account policy: #{@store.account_policy}"
      end
    end

    private def cmd_delete(r : Jargon::Result) : Nil
      id = r["id"].as_i
      if txn = @store.delete_transaction(id)
        puts "Deleted ##{txn.id}: #{txn.description}"
      else
        raise Error.new("no transaction with id #{id}")
      end
    end

    # --- budgets ---------------------------------------------------------

    private def cmd_recurring_add(r : Jargon::Result) : Nil
      amount = Money.parse(r["amount"].as_s)
      kind = r["kind"]?.try(&.as_s) || "expense"
      account = r["account"].as_s
      counter = r["counter"]?.try(&.as_s) || DEFAULT_ASSET_ACCOUNT
      cadence = r["every"].as_s
      start = r["start"]?.try(&.as_s) || today
      validate_date!(start)

      postings = Finfry.postings_for(kind, amount, account, counter)
      enforce_account_policy!(postings) # catch typo'd accounts when the rule is defined
      rule = @store.add_recurring_rule(desc_of(r), cadence, start, postings)
      puts "Added recurring ##{rule.id}: #{rule_label(rule)} every #{cadence}, next #{start}"
    end

    private def cmd_recurring_interest(r : Jargon::Result) : Nil
      card = r["card"].as_s
      interest_acct = r["account"]?.try(&.as_s) || "Expenses:Interest"
      cadence = r["every"]?.try(&.as_s) || "monthly"
      raise Error.new("unknown recurrence #{cadence.inspect} (one of: #{Recurrence.names.join(", ")})") unless Recurrence.valid?(cadence)
      start = r["start"]?.try(&.as_s) || today
      validate_date!(start)

      @store.set_account_meta(card, "apr", r["apr"].as_s) if r["apr"]?
      apr = @store.account_meta(card)["apr"]?
      raise Error.new("set the card's APR first: finfry accounts set #{card} apr <rate>  (or pass --apr)") unless apr

      memo = r["memo"]?.try(&.as_s) || "Interest on #{card}"
      postings = Finfry.postings_for("expense", 0_i64, interest_acct, card)
      enforce_account_policy!(postings) # interest + card accounts must be known

      rule = @store.add_recurring_rule(memo, cadence, start, postings, kind: "interest")
      puts "Added recurring interest ##{rule.id}: #{card} @ #{apr}% → #{interest_acct}, #{cadence}, next #{start}"
    end

    private def cmd_recurring_list(r : Jargon::Result) : Nil
      rules = @store.recurring_rules
      if rules.empty?
        puts "No recurring rules. Add one with 'finfry recurring add'."
        return
      end
      rules.each do |rule|
        tail = rule.active ? "" : "  (off)"
        puts "##{rule.id}  %-9s  next %s  %s%s" % {rule.cadence, rule.next_date, rule_label(rule), tail}
      end
      puts "(run 'finfry due' to review what's due)"
    end

    private def cmd_recurring_off(r : Jargon::Result) : Nil
      id = r["id"].as_i
      if @store.deactivate_rule(id)
        puts "Recurring ##{id} turned off"
      else
        raise Error.new("no recurring rule ##{id}")
      end
    end

    private def rule_label(rule : RecurringRule) : String
      return "#{rule.description} (computed)" if rule.kind == "interest"
      label_for(rule.description, rule.postings)
    end

    private def due_label(entry : DueEntry) : String
      label_for(entry.description, entry.postings)
    end

    private def label_for(description : String, postings : Array(Posting)) : String
      base = description.empty? ? postings.map(&.account).join(" / ") : description
      "#{base} (#{Money.format(postings.first.amount.abs)})"
    end

    private def cmd_due_list(r : Jargon::Result) : Nil
      @store.generate_due(today)
      entries = @store.due_entries.sort_by { |e| {e.date, e.id} }
      if entries.empty?
        puts "Nothing due."
        return
      end
      entries.each do |e|
        mark = case e.status
               when "ok"   then "  ✓ ok"
               when "skip" then "  ✗ skip"
               else             ""
               end
        puts "##{e.id}  #{e.date}  #{due_label(e)}#{mark}"
      end
      staged = entries.count { |e| e.status != "pending" }
      puts "(#{staged} staged — run 'finfry due post' to apply)" if staged > 0
    end

    private def cmd_due_stage(r : Jargon::Result, status : String) : Nil
      @store.generate_due(today)
      targets = due_targets(r)
      if targets.empty?
        puts "No matching due entries."
        return
      end
      targets.each { |e| e.status = status }
      @store.save
      verb = status == "pending" ? "reset" : status
      puts "#{verb}: #{targets.map(&.id).sort.join(", ")}"
    end

    private def due_targets(r : Jargon::Result) : Array(DueEntry)
      tokens = r["ids"].as_a.map(&.to_s) # tolerate strings (CLI) or numbers (AI)
      return @store.due_entries if tokens.includes?("all")
      ids = tokens.compact_map(&.to_i?)
      @store.due_entries.select { |e| ids.includes?(e.id) }
    end

    private def cmd_due_edit(r : Jargon::Result) : Nil
      @store.generate_due(today)
      id = r["id"].as_i
      entry = @store.due_entries.find { |e| e.id == id }
      raise Error.new("no due entry ##{id}") unless entry

      if a = r["amount"]?.try(&.as_s)
        amount = Money.parse(a)
        entry.postings = entry.postings.map { |p| Posting.new(p.account, p.amount < 0 ? -amount : amount) }
      end
      if d = r["date"]?.try(&.as_s)
        validate_date!(d)
        entry.date = d
      end
      if m = r["memo"]?.try(&.as_s)
        entry.description = m
      end
      entry.status = "ok"
      @store.save
      puts "##{entry.id}  #{entry.date}  #{due_label(entry)}  ✓ ok"
    end

    private def cmd_due_post(r : Jargon::Result) : Nil
      @store.generate_due(today)
      oks = @store.due_entries.select { |e| e.status == "ok" }
      skips = @store.due_entries.select { |e| e.status == "skip" }
      if oks.empty? && skips.empty?
        puts "Nothing staged. Use 'finfry due ok <id>' or 'finfry due skip <id>' first."
        return
      end

      oks.each { |e| commit(e.date, e.description, e.postings, e.cadence) }
      @store.remove_due_entries((oks + skips).map(&.id))
      puts "Posted #{oks.size}, skipped #{skips.size}."
    end

    private def cmd_budget_set(r : Jargon::Result) : Nil
      account = r["account"].as_s
      limit = Money.parse(r["amount"].as_s)
      @store.changeset("budget #{account} = #{Money.format(limit)}", now) do
        @store.set_budget(account, limit)
      end
      puts "Budget for #{account} set to #{Money.format(limit)}/month"
    end

    private def cmd_budget_list(r : Jargon::Result) : Nil
      month = r["month"]?.try(&.as_s) || current_month
      validate_month!(month)
      budgets = @store.budgets

      if budgets.empty?
        puts "No budgets set. Use 'finfry budget set <account> <amount>'."
        return
      end

      puts "Budgets for #{month}"
      puts "%-22s  %12s  %12s  %12s" % {"ACCOUNT", "SPENT", "LIMIT", "REMAINING"}
      budgets.to_a.sort_by { |(account, _)| account }.each do |(account, limit)|
        spent = @store.spent(account, month)
        remaining = limit - spent
        flag = remaining < 0 ? "  OVER" : ""
        puts "%-22s  %12s  %12s  %12s%s" % {
          account, Money.format(spent), Money.format(limit), Money.format(remaining), flag,
        }
      end
    end

    private def cmd_budget_rm(r : Jargon::Result) : Nil
      account = r["account"].as_s
      removed = @store.changeset("remove budget #{account}", now) { @store.remove_budget(account) }
      if removed
        puts "Removed budget for #{account}"
      else
        raise Error.new("no budget set for #{account}")
      end
    end

    # --- helpers ---------------------------------------------------------

    private def date_of(r : Jargon::Result) : String
      r["date"]?.try(&.as_s) || today
    end

    private def desc_of(r : Jargon::Result) : String
      r["memo"]?.try(&.as_s) || ""
    end

    private def recurrence_of(r : Jargon::Result) : String?
      r["recurrence"]?.try(&.as_s)
    end

    # Income/Liabilities/Equity are credit-normal; flip their sign so reports
    # read as positive numbers.
    private def display_cents(account : String, cents : Int64) : Int64
      credit_normal = {"Income", "Liabilities", "Equity"}.any? { |p| account.starts_with?(p) }
      credit_normal ? -cents : cents
    end

    # A transaction's "size": the largest leg by absolute value. For a balanced
    # entry that's the amount that moved (the spend/earn/transfer figure), so it
    # is what `register --min/--max` filters on.
    private def txn_magnitude(txn : Transaction) : Int64
      txn.postings.max_of { |p| p.amount.abs }
    end

    # A finfry command exposed to the AI: tool name, the dispatch subcommand it
    # maps to, whether it mutates (writes are deferred for approval), a
    # description, and the JSON Schema of its input.
    struct AgentTool
      getter name : String
      getter subcommand : String
      getter write : Bool
      getter description : String
      getter schema : JSON::Any

      def initialize(@name, @subcommand, @write, @description, @schema)
      end
    end

    # The agent's tools as Claude tool definitions (built from the specs).
    def agent_tools : Array(AI::ToolDef)
      agent_tools_spec.map { |s| AI::ToolDef.new(s.name, s.description, s.schema) }
    end

    # Execute one agent tool directly (no plan deferral) and return its captured
    # output plus whether it errored. Used by the MCP server, where the client
    # harness owns approval. Both reads and writes execute immediately; each
    # write records its own undoable changeset via `commit`.
    def execute_tool(name : String, arguments : JSON::Any) : {String, Bool}
      spec = agent_tools_spec.find { |s| s.name == name }
      return {"unknown tool '#{name}'", true} unless spec
      output = capture { dispatch(Jargon::Result.new(arguments, subcommand: spec.subcommand)) }
      {output.blank? ? "(done)" : output, false}
    rescue ex : Money::Error | Error
      {"error: #{ex.message}", true}
    end

    # The tools the agent may use. Read tools run live; write tools are queued.
    # `delete` and `accounts policy` are deliberately withheld — the AI shouldn't
    # hard-delete or weaken its own guardrails.
    private def agent_tools_spec : Array(AgentTool)
      cadence = Recurrence.names.to_json
      [
        AgentTool.new("register", "register", false, "List transactions (the register). Filters: account (subtree), month (YYYY-MM), since/until (YYYY-MM-DD), min/max (largest leg amount), match (memo text), limit.",
          JSON.parse(%({"type":"object","properties":{"account":{"type":"string"},"month":{"type":"string"},"since":{"type":"string"},"until":{"type":"string"},"min":{"type":"string"},"max":{"type":"string"},"match":{"type":"string"},"limit":{"type":"integer"}}}))),
        AgentTool.new("balance", "balance", false, "Show account balances, optionally limited to an account subtree (prefix).",
          JSON.parse(%({"type":"object","properties":{"prefix":{"type":"string"}}}))),
        AgentTool.new("income_statement", "report income", false, "Income statement for a month (YYYY-MM; default current).",
          JSON.parse(%({"type":"object","properties":{"month":{"type":"string"}}}))),
        AgentTool.new("balance_sheet", "report balance-sheet", false, "Balance sheet: Assets / Liabilities / Equity with subtotals and the accounting-equation integrity check.",
          JSON.parse(%({"type":"object","properties":{"date":{"type":"string"}}}))),
        AgentTool.new("daily", "report daily", false, "Per-day amortized cost of recurring items.",
          JSON.parse(%({"type":"object","properties":{}}))),
        AgentTool.new("accounts", "accounts list", false, "List the known accounts.",
          JSON.parse(%({"type":"object","properties":{}}))),
        AgentTool.new("history", "history", false, "Recent change history (optional limit).",
          JSON.parse(%({"type":"object","properties":{"limit":{"type":"integer"}}}))),
        AgentTool.new("reconcile", "reconcile", false, "Reconciliation status for an account: cleared balance (reconciled + staged), ledger balance, the working list of not-yet-reconciled transactions, and (with statement) whether they agree. Read-only; staging/committing is a human task.",
          JSON.parse(%({"type":"object","properties":{"account":{"type":"string"},"statement":{"type":"string"}},"required":["account"]}))),
        AgentTool.new("spend", "spend", true, "Record an expense. account = the Expenses:* account; from = the asset/liability paid from (default #{DEFAULT_ASSET_ACCOUNT}).",
          JSON.parse(%({"type":"object","properties":{"amount":{"type":"string"},"account":{"type":"string"},"from":{"type":"string"},"memo":{"type":"string"},"date":{"type":"string"},"recurrence":{"type":"string","enum":#{cadence}}},"required":["amount","account"]}))),
        AgentTool.new("earn", "earn", true, "Record income. account = the Income:* account; to = the asset received into (default #{DEFAULT_ASSET_ACCOUNT}).",
          JSON.parse(%({"type":"object","properties":{"amount":{"type":"string"},"account":{"type":"string"},"to":{"type":"string"},"memo":{"type":"string"},"date":{"type":"string"},"recurrence":{"type":"string","enum":#{cadence}}},"required":["amount","account"]}))),
        AgentTool.new("transfer", "transfer", true, "Move money between two accounts (account-to-account; neither income nor expense).",
          JSON.parse(%({"type":"object","properties":{"amount":{"type":"string"},"from":{"type":"string"},"to":{"type":"string"},"memo":{"type":"string"},"date":{"type":"string"}},"required":["amount","from","to"]}))),
        AgentTool.new("budget_set", "budget set", true, "Set a monthly budget for an account.",
          JSON.parse(%({"type":"object","properties":{"account":{"type":"string"},"amount":{"type":"string"}},"required":["account","amount"]}))),
        AgentTool.new("budget_remove", "budget rm", true, "Remove an account's budget.",
          JSON.parse(%({"type":"object","properties":{"account":{"type":"string"}},"required":["account"]}))),
        AgentTool.new("accounts_add", "accounts add", true, "Declare new accounts in the chart. Do this before spending to a brand-new account.",
          JSON.parse(%({"type":"object","properties":{"names":{"type":"array","items":{"type":"string"}}},"required":["names"]}))),
        AgentTool.new("accounts_rename", "accounts rename", true, "Rename an account everywhere (merges into the target if it exists).",
          JSON.parse(%({"type":"object","properties":{"from":{"type":"string"},"to":{"type":"string"}},"required":["from","to"]}))),
        AgentTool.new("set_account_metadata", "accounts set", true, "Record a metadata key/value on an account (e.g. apr, limit, due-day, bank). Visible in the account chart.",
          JSON.parse(%({"type":"object","properties":{"account":{"type":"string"},"key":{"type":"string"},"value":{"type":"string"}},"required":["account","key","value"]}))),
        AgentTool.new("recurring", "recurring list", false, "List recurring rules.",
          JSON.parse(%({"type":"object","properties":{}}))),
        AgentTool.new("recurring_add", "recurring add", true, "Define a recurring rule. kind expense/income/transfer; every is the cadence; start optional (back-date to catch up).",
          JSON.parse(%({"type":"object","properties":{"amount":{"type":"string"},"account":{"type":"string"},"counter":{"type":"string"},"kind":{"type":"string","enum":["expense","income","transfer"]},"every":{"type":"string","enum":#{cadence}},"start":{"type":"string"},"memo":{"type":"string"}},"required":["amount","account","every"]}))),
        AgentTool.new("recurring_interest", "recurring interest", true, "Define a computed credit-card interest rule (amount = card APR x balance owed each cycle).",
          JSON.parse(%({"type":"object","properties":{"card":{"type":"string"},"account":{"type":"string"},"every":{"type":"string","enum":#{cadence}},"apr":{"type":"string"},"start":{"type":"string"},"memo":{"type":"string"}},"required":["card"]}))),
        AgentTool.new("recurring_off", "recurring off", true, "Turn off a recurring rule (stops generating new occurrences).",
          JSON.parse(%({"type":"object","properties":{"id":{"type":"integer"}},"required":["id"]}))),
        AgentTool.new("due", "due list", false, "Show the due queue (occurrences awaiting review). Listing also materializes newly-due ones.",
          JSON.parse(%({"type":"object","properties":{}}))),
        AgentTool.new("due_ok", "due ok", true, "Stage due entries to post (array of ids, or [\"all\"]).",
          JSON.parse(%({"type":"object","properties":{"ids":{"type":"array","items":{"type":"string"}}},"required":["ids"]}))),
        AgentTool.new("due_skip", "due skip", true, "Stage due entries to drop (array of ids, or [\"all\"]).",
          JSON.parse(%({"type":"object","properties":{"ids":{"type":"array","items":{"type":"string"}}},"required":["ids"]}))),
        AgentTool.new("due_edit", "due edit", true, "Adjust a due entry before posting (marks it ok).",
          JSON.parse(%({"type":"object","properties":{"id":{"type":"integer"},"amount":{"type":"string"},"date":{"type":"string"},"memo":{"type":"string"}},"required":["id"]}))),
        AgentTool.new("due_post", "due post", true, "Apply staged decisions: post the ok'd entries, drop the skipped.",
          JSON.parse(%({"type":"object","properties":{}}))),
      ]
    end

    private def agent_system_prompt : String
      accounts = @store.known_accounts
      account_list = accounts.empty? ? "(none yet)" : accounts.map { |a| "#{a}#{meta_suffix(a)}" }.join("\n")
      <<-PROMPT
      You are finfry's assistant, managing a personal double-entry ledger through tools.

      Today is #{today}. Resolve relative dates ("yesterday", "last Friday") to YYYY-MM-DD.

      Accounts are hierarchical and colon-separated:
        Assets:* (money you have), Liabilities:* (money you owe),
        Income:* (where money comes from), Expenses:* (where it goes).
      Default money account: #{DEFAULT_ASSET_ACCOUNT}. Amounts are positive decimal strings.

      Known accounts — REUSE one whenever it fits; only create a new one (same convention) when none does:
      #{account_list}

      How to work:
      - Use the read tools (list, balance, report, daily, accounts, history) freely to
        answer questions and to gather what you need before making any change.
      - To change the ledger, call the write tools (spend, earn, transfer, budget_set,
        budget_remove, accounts_add, accounts_rename) with concrete values. These do
        NOT take effect immediately — finfry collects them and asks the user to approve
        the plan, so express exactly what should happen.
      - If a change needs an account that isn't known yet, call accounts_add for it
        first, then the spend/earn that uses it.
      - Recurring bills: `recurring`/`due` show rules and what's due. To record due
        items, stage them (due_ok / due_skip, optionally due_edit a variable
        amount) then due_post — only ok'd entries post, skipped ones drop.
      - Finish with a brief plain-language summary of what you found or queued.
      PROMPT
    end

    private def today : String
      Time.local.to_s("%Y-%m-%d")
    end

    private def now : String
      Time.local.to_s("%Y-%m-%d %H:%M")
    end

    private def current_month : String
      Time.local.to_s("%Y-%m")
    end

    private def validate_date!(date : String) : Nil
      unless date =~ /\A\d{4}-\d{2}-\d{2}\z/
        raise Error.new("invalid date #{date.inspect} (expected YYYY-MM-DD)")
      end
    end

    private def validate_month!(month : String) : Nil
      unless month =~ /\A\d{4}-\d{2}\z/
        raise Error.new("invalid month #{month.inspect} (expected YYYY-MM)")
      end
    end

    private def abort_with(message : String?) : NoReturn
      STDERR.puts "finfry: #{message}"
      exit 1
    end
  end
end
