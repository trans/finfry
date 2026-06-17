require "jargon"
require "./store"
require "./money"
require "./recurrence"
require "./ai"

module Finfry
  # Wires the Jargon-defined CLI to the `Store` and renders output. Every entry
  # path (manual commands now, the AI layer later) funnels through `commit` and
  # `render`, so the ledger logic lives here rather than in the CLI handlers.
  class App
    def initialize(@store : Store = Store.new)
    end

    def run(argv : Array(String)) : Nil
      cli.run(argv) { |result| dispatch(result) }
    rescue ex : Money::Error | Error
      abort_with(ex.message)
    end

    # --- shared core (also used by the future AI/REPL layer) -------------

    # Validate, persist, and echo a transaction. The single commit path.
    def commit(date : String, description : String, postings : Array(Posting),
               recurrence : String? = nil) : Transaction
      validate_date!(date)
      if recurrence && !Recurrence.valid?(recurrence)
        raise Error.new("unknown recurrence #{recurrence.inspect} (one of: #{Recurrence.names.join(", ")})")
      end

      txn = @store.record(date, description, postings, recurrence)
      suffix = txn.recurrence ? " (#{txn.recurrence})" : ""
      puts "Recorded ##{txn.id}#{suffix}:"
      puts render(txn)
      txn
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
        description: Record a transaction from plain English (needs ANTHROPIC_API_KEY)
        positional: [text]
        properties:
          text: {type: string, description: "What happened, in plain English (or piped via stdin)"}
          "yes": {type: boolean, short: y, description: "Record without confirming"}
        YAML

      cli.subcommand "spend", yaml: <<-YAML
        type: object
        description: Record an expense
        positional: [amount, account]
        properties:
          amount: {type: string, description: "Amount, e.g. 50 or 12.50"}
          account: {type: string, description: "Expense account, e.g. Expenses:Food:Coffee"}
          from: {type: string, short: f, description: "Account paid from", default: #{DEFAULT_ASSET_ACCOUNT}}
          description: {type: string, short: m, description: "Note", default: ""}
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
          description: {type: string, short: m, description: "Note", default: ""}
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
          description: {type: string, short: m, description: "Note", default: ""}
          date: {type: string, short: d, description: "Date YYYY-MM-DD (default today)"}
        required: [amount, from, to]
        YAML

      cli.subcommand "add", yaml: <<-YAML
        type: object
        description: Record a transaction with arbitrary postings (splits)
        positional: [posts]
        properties:
          posts: {type: array, description: "ACCOUNT AMOUNT pairs; a trailing lone ACCOUNT is inferred to balance"}
          description: {type: string, short: m, description: "Note", default: ""}
          date: {type: string, short: d, description: "Date YYYY-MM-DD (default today)"}
          recurrence: {type: string, short: r, description: "Recurs on a cadence", enum: [#{Recurrence.names.join(", ")}]}
        required: [posts]
        YAML

      cli.subcommand "list", yaml: <<-YAML
        type: object
        description: List transactions
        properties:
          account: {type: string, short: a, description: "Only transactions touching this account subtree"}
          month: {type: string, short: m, description: "Only this month (YYYY-MM)"}
          limit: {type: integer, short: n, description: "Show only the most recent N"}
        YAML

      cli.subcommand "balance", yaml: <<-YAML
        type: object
        description: Show account balances
        positional: [prefix]
        properties:
          prefix: {type: string, description: "Limit to this account subtree"}
        YAML

      cli.subcommand "report", yaml: <<-YAML
        type: object
        description: Income statement for a month
        properties:
          month: {type: string, short: m, description: "Month as YYYY-MM (default current)"}
        YAML

      cli.subcommand "daily", yaml: <<-YAML
        type: object
        description: Per-day cost of recurring items
        YAML

      cli.subcommand "accounts", yaml: <<-YAML
        type: object
        description: List all accounts in use
        YAML

      cli.subcommand "path", yaml: <<-YAML
        type: object
        description: Print the path to the active ledger file
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

      cli
    end

    # --- dispatch --------------------------------------------------------

    private def dispatch(result : Jargon::Result) : Nil
      case result.subcommand
      when "ai"          then cmd_ai(result)
      when "spend"       then cmd_spend(result)
      when "earn"        then cmd_earn(result)
      when "transfer"    then cmd_transfer(result)
      when "add"         then cmd_add(result)
      when "list"        then cmd_list(result)
      when "balance"     then cmd_balance(result)
      when "report"      then cmd_report(result)
      when "daily"       then cmd_daily(result)
      when "accounts"    then cmd_accounts(result)
      when "path"        then cmd_path(result)
      when "delete"      then cmd_delete(result)
      when "budget set"  then cmd_budget_set(result)
      when "budget list" then cmd_budget_list(result)
      when "budget rm"   then cmd_budget_rm(result)
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
      raise Error.new("no description given") if text.empty?

      intent = AI.from_env.extract(
        text,
        accounts: @store.accounts,
        today: today,
        default_asset: DEFAULT_ASSET_ACCOUNT,
      )

      amount = Money.parse(intent.amount)
      recurrence = intent.recurrence_or_nil
      postings = Finfry.postings_for(intent.kind, amount, intent.account, intent.counter_account)

      suffix = recurrence ? " (#{recurrence})" : ""
      puts "Proposed#{suffix}: #{intent.date}  #{intent.description}"
      puts render(Transaction.new(0, intent.date, intent.description, postings, recurrence))

      unless r["yes"]?.try(&.as_bool)
        if piped || !STDIN.tty?
          raise Error.new("re-run with --yes to record (can't prompt when input is piped)")
        end
        return puts("Not recorded.") unless confirm?("Record this?")
      end

      commit(intent.date, intent.description, postings, recurrence)
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

    private def cmd_list(r : Jargon::Result) : Nil
      txns = @store.transactions
      if account = r["account"]?.try(&.as_s)
        txns = txns.select(&.touches?(account))
      end
      if month = r["month"]?.try(&.as_s)
        txns = txns.select(&.in_month?(month))
      end
      txns = txns.sort_by { |t| {t.date, t.id} }
      if limit = r["limit"]?.try(&.as_i)
        txns = txns.last(limit)
      end

      if txns.empty?
        puts "No transactions found."
        return
      end

      txns.each do |t|
        header = "##{t.id}  #{t.date}"
        header += "  #{t.description}" unless t.description.empty?
        header += "  (#{t.recurrence})" if t.recurrence
        puts header
        puts render(t)
      end
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

    private def cmd_path(r : Jargon::Result) : Nil
      puts @store.path
    end

    private def cmd_accounts(r : Jargon::Result) : Nil
      accounts = @store.accounts
      if accounts.empty?
        puts "No accounts yet."
      else
        accounts.each { |a| puts a }
      end
    end

    private def cmd_delete(r : Jargon::Result) : Nil
      id = r["id"].as_i
      if txn = @store.delete_transaction(id)
        puts "Deleted ##{txn.id}: #{txn.description}"
      else
        abort_with("no transaction with id #{id}")
      end
    end

    # --- budgets ---------------------------------------------------------

    private def cmd_budget_set(r : Jargon::Result) : Nil
      account = r["account"].as_s
      limit = Money.parse(r["amount"].as_s)
      @store.set_budget(account, limit)
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
      if @store.remove_budget(account)
        puts "Removed budget for #{account}"
      else
        abort_with("no budget set for #{account}")
      end
    end

    # --- helpers ---------------------------------------------------------

    private def date_of(r : Jargon::Result) : String
      r["date"]?.try(&.as_s) || today
    end

    private def desc_of(r : Jargon::Result) : String
      r["description"]?.try(&.as_s) || ""
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

    private def today : String
      Time.local.to_s("%Y-%m-%d")
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
