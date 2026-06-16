require "jargon"
require "./store"
require "./money"

module Finfry
  # Wires the Jargon-defined CLI to the `Store` and renders output.
  class App
    def initialize(@store : Store = Store.new)
    end

    def run(argv : Array(String)) : Nil
      cli.run(argv) { |result| dispatch(result) }
    rescue ex : Money::Error
      abort_with(ex.message)
    end

    # --- CLI definition --------------------------------------------------

    private def cli : Jargon::CLI
      cli = Jargon.new("finfry")

      cli.subcommand "add", yaml: <<-YAML
        type: object
        description: Record an expense (or income with --income)
        positional: [amount, description]
        properties:
          amount: {type: string, description: "Amount, e.g. 12.50"}
          description: {type: string, description: "What it was for", default: ""}
          category: {type: string, short: c, description: "Category", default: uncategorized}
          date: {type: string, short: d, description: "Date as YYYY-MM-DD (default today)"}
          income: {type: boolean, description: "Record as income instead of an expense"}
        required: [amount]
        YAML

      cli.subcommand "list", yaml: <<-YAML
        type: object
        description: List recorded transactions
        properties:
          category: {type: string, short: c, description: "Only this category"}
          month: {type: string, short: m, description: "Only this month (YYYY-MM)"}
          limit: {type: integer, short: n, description: "Show only the most recent N"}
        YAML

      cli.subcommand "report", yaml: <<-YAML
        type: object
        description: Summarize a month by category
        properties:
          month: {type: string, short: m, description: "Month as YYYY-MM (default current)"}
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
        description: Set a monthly budget for a category
        positional: [category, amount]
        properties:
          category: {type: string}
          amount: {type: string, description: "Monthly limit, e.g. 400"}
        required: [category, amount]
        YAML
      budget.subcommand "list", yaml: <<-YAML
        type: object
        description: Show budgets vs. this month's spending
        properties:
          month: {type: string, short: m, description: "Month as YYYY-MM (default current)"}
        YAML
      budget.subcommand "rm", yaml: <<-YAML
        type: object
        description: Remove a category's budget
        positional: [category]
        properties:
          category: {type: string}
        required: [category]
        YAML
      cli.subcommand "budget", budget

      cli
    end

    # --- dispatch --------------------------------------------------------

    private def dispatch(result : Jargon::Result) : Nil
      case result.subcommand
      when "add"         then cmd_add(result)
      when "list"        then cmd_list(result)
      when "report"      then cmd_report(result)
      when "delete"      then cmd_delete(result)
      when "budget set"  then cmd_budget_set(result)
      when "budget list" then cmd_budget_list(result)
      when "budget rm"   then cmd_budget_rm(result)
      else
        puts cli.help
      end
    end

    # --- commands --------------------------------------------------------

    private def cmd_add(r : Jargon::Result) : Nil
      amount = Money.parse(r["amount"].as_s)
      kind = (r["income"]?.try(&.as_bool) || false) ? "income" : "expense"
      date = (r["date"]?.try(&.as_s)) || today
      validate_date!(date)

      txn = @store.add_transaction(
        date: date,
        amount: amount,
        category: r["category"]?.try(&.as_s) || "uncategorized",
        description: r["description"]?.try(&.as_s) || "",
        kind: kind,
      )

      verb = txn.income? ? "income" : "expense"
      puts "Added #{verb} ##{txn.id}: #{Money.format(txn.amount)} [#{txn.category}] on #{txn.date}"
    end

    private def cmd_list(r : Jargon::Result) : Nil
      txns = @store.transactions
      if cat = r["category"]?.try(&.as_s)
        txns = txns.select { |t| t.category == cat }
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

      puts "%-4s  %-10s  %12s  %-14s  %s" % {"ID", "DATE", "AMOUNT", "CATEGORY", "DESCRIPTION"}
      txns.each do |t|
        amount = (t.income? ? "+" : "-") + Money.format(t.amount)
        puts "%-4d  %-10s  %12s  %-14s  %s" % {t.id, t.date, amount, t.category, t.description}
      end
    end

    private def cmd_report(r : Jargon::Result) : Nil
      month = (r["month"]?.try(&.as_s)) || current_month
      validate_month!(month)
      txns = @store.transactions.select(&.in_month?(month))

      if txns.empty?
        puts "No transactions for #{month}."
        return
      end

      by_category = Hash(String, Int64).new(0_i64)
      income = 0_i64
      txns.each do |t|
        if t.expense?
          by_category[t.category] += t.amount
        else
          income += t.amount
        end
      end

      expenses = by_category.values.sum(0_i64)

      puts "Report for #{month}"
      puts "─" * 34
      by_category.to_a.sort_by { |(_, v)| -v }.each do |(cat, amt)|
        puts "%-20s  %12s" % {cat, Money.format(amt)}
      end
      puts "─" * 34
      puts "%-20s  %12s" % {"Expenses", Money.format(expenses)}
      puts "%-20s  %12s" % {"Income", Money.format(income)}
      puts "%-20s  %12s" % {"Net", Money.format(income - expenses)}
    end

    private def cmd_delete(r : Jargon::Result) : Nil
      id = r["id"].as_i
      if txn = @store.delete_transaction(id)
        puts "Deleted ##{txn.id}: #{Money.format(txn.amount)} [#{txn.category}]"
      else
        abort_with("no transaction with id #{id}")
      end
    end

    private def cmd_budget_set(r : Jargon::Result) : Nil
      category = r["category"].as_s
      limit = Money.parse(r["amount"].as_s)
      @store.set_budget(category, limit)
      puts "Budget for #{category} set to #{Money.format(limit)}/month"
    end

    private def cmd_budget_list(r : Jargon::Result) : Nil
      month = (r["month"]?.try(&.as_s)) || current_month
      validate_month!(month)
      budgets = @store.budgets

      if budgets.empty?
        puts "No budgets set. Use 'finfry budget set <category> <amount>'."
        return
      end

      puts "Budgets for #{month}"
      puts "%-14s  %12s  %12s  %12s" % {"CATEGORY", "SPENT", "LIMIT", "REMAINING"}
      budgets.to_a.sort_by { |(cat, _)| cat }.each do |(cat, limit)|
        spent = @store.spent(cat, month)
        remaining = limit - spent
        flag = remaining < 0 ? "  OVER" : ""
        puts "%-14s  %12s  %12s  %12s%s" % {
          cat, Money.format(spent), Money.format(limit), Money.format(remaining), flag,
        }
      end
    end

    private def cmd_budget_rm(r : Jargon::Result) : Nil
      category = r["category"].as_s
      if @store.remove_budget(category)
        puts "Removed budget for #{category}"
      else
        abort_with("no budget set for #{category}")
      end
    end

    # --- helpers ---------------------------------------------------------

    private def today : String
      Time.local.to_s("%Y-%m-%d")
    end

    private def current_month : String
      Time.local.to_s("%Y-%m")
    end

    private def validate_date!(date : String) : Nil
      unless date =~ /\A\d{4}-\d{2}-\d{2}\z/
        abort_with("invalid date #{date.inspect} (expected YYYY-MM-DD)")
      end
    end

    private def validate_month!(month : String) : Nil
      unless month =~ /\A\d{4}-\d{2}\z/
        abort_with("invalid month #{month.inspect} (expected YYYY-MM)")
      end
    end

    private def abort_with(message : String?) : NoReturn
      STDERR.puts "finfry: #{message}"
      exit 1
    end
  end
end
