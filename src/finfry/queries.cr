require "./app"

# The read side of finfry, split from its rendering. Each query returns a plain
# value the CLI prints as text and the web UI renders as HTML, so both stay in
# agreement about what a report *is*. Amounts in these views are already
# display-signed (credit-normal accounts flipped positive) unless noted.
module Finfry
  # One register line. In an account view `leg` is that account's own movement
  # in the transaction and `running` the balance after it; both nil otherwise.
  struct RegisterRow
    getter txn : Transaction
    getter leg : Int64?
    getter running : Int64?

    def initialize(@txn, @leg = nil, @running = nil)
    end
  end

  struct RegisterView
    getter account : String?
    getter rows : Array(RegisterRow)

    def initialize(@account, @rows)
    end

    def empty? : Bool
      rows.empty?
    end
  end

  # Income statement for one month: per-account lines (largest first) and totals.
  struct IncomeStatement
    getter month : String
    getter income : Array({String, Int64})
    getter expenses : Array({String, Int64})

    def initialize(@month, @income, @expenses)
    end

    def total_income : Int64
      income.sum(0_i64) { |(_, cents)| cents }
    end

    def total_expenses : Int64
      expenses.sum(0_i64) { |(_, cents)| cents }
    end

    def net : Int64
      total_income - total_expenses
    end

    def empty? : Bool
      income.empty? && expenses.empty?
    end
  end

  # Recurring commitments split by direction, with per-day totals.
  struct DailyReport
    getter expenses : Array(RecurringItem)
    getter incomes : Array(RecurringItem)

    def initialize(@expenses, @incomes)
    end

    def expense_per_day : Float64
      expenses.sum(0.0, &.per_day)
    end

    def income_per_day : Float64
      incomes.sum(0.0, &.per_day)
    end

    def net_per_day : Float64
      income_per_day - expense_per_day
    end

    def empty? : Bool
      expenses.empty? && incomes.empty?
    end
  end

  # A known account with its balance, whether any posting uses it, and metadata.
  struct AccountRow
    getter name : String
    getter balance : Int64
    getter? used : Bool
    getter meta : Hash(String, String)

    def initialize(@name, @balance, @used, @meta)
    end
  end

  struct BudgetRow
    getter account : String
    getter spent : Int64
    getter limit : Int64

    def initialize(@account, @spent, @limit)
    end

    def remaining : Int64
      limit - spent
    end

    def over? : Bool
      remaining < 0
    end
  end

  struct HistoryRow
    getter changeset : Changeset
    getter? reversed : Bool

    def initialize(@changeset, @reversed)
    end
  end

  # One not-yet-reconciled transaction on the account's working list.
  struct ReconcileRow
    getter txn : Transaction
    getter amount : Int64
    getter? cleared : Bool

    def initialize(@txn, @amount, @cleared)
    end
  end

  # The reconciliation view for one account (see `App#reconciliation`).
  struct ReconcileView
    getter account : String
    getter cleared : Int64 # reconciled + staged: what a statement should match
    getter ledger : Int64
    getter last : Reconciliation?
    getter rows : Array(ReconcileRow)
    getter statement : Int64?

    def initialize(@account, @cleared, @ledger, @last, @rows, @statement)
    end

    def staged_count : Int32
      rows.count(&.cleared?)
    end

    # statement − cleared, when a statement was given.
    def difference : Int64?
      statement.try { |s| s - cleared }
    end

    def matches? : Bool
      difference == 0_i64
    end
  end

  class App
    # --- queries ---------------------------------------------------------
    #
    # Shared by the CLI renderers below and the web UI. Filters mirror the
    # `register` command's flags; `min`/`max` are already-parsed cents.

    def register(account : String? = nil, month : String? = nil, since : String? = nil,
                 until_date : String? = nil, min : Int64? = nil, max : Int64? = nil,
                 match : String? = nil, limit : Int32? = nil) : RegisterView
      txns = @store.transactions

      # When filtered to an account, precompute the true running balance at each
      # of its transactions (over full history, in date order) so the column
      # stays accurate even when later filters/limit show only a window.
      running = nil
      if account
        running = {} of Int32 => Int64
        bal = 0_i64
        txns.select(&.touches?(account)).sort_by { |t| {t.date, t.id} }.each do |t|
          bal += account_leg(t, account)
          running[t.id] = display_cents(account, bal)
        end
        txns = txns.select(&.touches?(account))
      end
      txns = txns.select(&.in_month?(month)) if month
      txns = txns.select { |t| t.date >= since } if since
      txns = txns.select { |t| t.date <= until_date } if until_date
      txns = txns.select { |t| txn_magnitude(t) >= min } if min
      txns = txns.select { |t| txn_magnitude(t) <= max } if max
      if match
        needle = match.downcase
        txns = txns.select { |t| t.description.downcase.includes?(needle) }
      end
      txns = txns.sort_by { |t| {t.date, t.id} }
      txns = txns.last(limit) if limit

      rows = txns.map do |t|
        if account && running
          RegisterRow.new(t, display_cents(account, account_leg(t, account)), running[t.id])
        else
          RegisterRow.new(t)
        end
      end
      RegisterView.new(account, rows)
    end

    # Display-signed balances, sorted by account name.
    def balances(prefix : String? = nil) : Array({String, Int64})
      @store.balances(prefix).to_a
        .sort_by { |(account, _)| account }
        .map { |(account, cents)| {account, display_cents(account, cents)} }
    end

    def income_statement(month : String) : IncomeStatement
      validate_month!(month)
      income = Hash(String, Int64).new(0_i64)
      expenses = Hash(String, Int64).new(0_i64)
      @store.transactions.each do |t|
        next unless t.in_month?(month)
        t.postings.each do |p|
          income[p.account] -= p.amount if p.account.starts_with?("Income") # credit-normal
          expenses[p.account] += p.amount if p.account.starts_with?("Expenses")
        end
      end
      IncomeStatement.new(month,
        income.to_a.sort_by { |(_, cents)| -cents },
        expenses.to_a.sort_by { |(_, cents)| -cents })
    end

    def balance_sheet(as_of : String? = nil) : BalanceSheet
      validate_date!(as_of) if as_of
      Finfry.balance_sheet(@store.balances(up_to: as_of))
    end

    def daily : DailyReport
      items = Finfry.recurring_items(@store.transactions)
      DailyReport.new(items.select(&.expense?), items.select(&.income?))
    end

    def chart : Array(AccountRow)
      used = @store.used_accounts.to_set
      balances = @store.balances
      @store.known_accounts.map do |a|
        AccountRow.new(a, display_cents(a, balances[a]? || 0_i64), used.includes?(a), @store.account_meta(a))
      end
    end

    def budgets(month : String) : Array(BudgetRow)
      validate_month!(month)
      @store.budgets.to_a
        .sort_by { |(account, _)| account }
        .map { |(account, limit)| BudgetRow.new(account, @store.spent(account, month), limit) }
    end

    # Newest first.
    def history(limit : Int32? = nil) : Array(HistoryRow)
      sets = @store.changesets.reverse
      sets = sets.first(limit) if limit
      sets.map { |cs| HistoryRow.new(cs, !cs.reversal? && @store.reversed?(cs.id)) }
    end

    # The due queue, materializing anything newly due first. Oldest first.
    def due_queue : Array(DueEntry)
      @store.generate_due(today)
      @store.due_entries.sort_by { |e| {e.date, e.id} }
    end

    # Reconciliation status: the working list (every not-yet-reconciled
    # transaction with a posting on the account, staged ones flagged), the
    # cleared balance (committed + staged), the full ledger balance, and — with
    # a statement — the difference to it.
    def reconciliation(account : String, statement : Int64? = nil) : ReconcileView
      cleared = display_cents(account, @store.reconciled_balance(account) + @store.cleared_balance(account))
      ledger = display_cents(account, @store.balances[account]? || 0_i64)
      staged = @store.cleared_ids(account).to_set
      rows = reconcile_working_list(account).map do |t|
        amount = display_cents(account, t.postings.sum(0_i64) { |p| p.account == account ? p.amount : 0_i64 })
        ReconcileRow.new(t, amount, staged.includes?(t.id))
      end
      ReconcileView.new(account, cleared, ledger, @store.last_reconciliation(account), rows, statement)
    end

    # --- habits: what the book already knows, for smarter defaults -------

    # Known accounts, most recently used first; never-used ones last,
    # alphabetically. Ordering only — every account is always offered.
    def accounts_by_recency : Array(String)
      last_used = {} of String => String
      @store.transactions.each do |t|
        t.postings.each { |p| last_used[p.account] = t.date if (last_used[p.account]? || "") < t.date }
      end
      @store.known_accounts.sort { |a, b| compare_recency(a, b, last_used) }
    end

    # The funding account you used last (the credit leg of the most recent
    # transaction that has an asset/liability one), else the default.
    def usual_funding_account : String
      @store.transactions.sort_by { |t| {t.date, t.id} }.reverse_each do |t|
        if p = t.postings.find { |p| p.amount < 0 && funding?(p.account) }
          return p.account
        end
      end
      DEFAULT_ASSET_ACCOUNT
    end

    # The most recent transaction recorded under this memo (case-insensitive;
    # exact match first, then prefix), so a repeat entry can start from it.
    def recall(memo : String) : Transaction?
      needle = memo.strip.downcase
      return nil if needle.empty?
      ordered = @store.transactions.sort_by { |t| {t.date, t.id} }.reverse
      ordered.find { |t| t.description.downcase == needle } ||
        ordered.find { |t| t.description.downcase.starts_with?(needle) }
    end

    # Distinct memos, most recent first.
    def recent_memos(limit : Int32 = 60) : Array(String)
      seen = Set(String).new
      out = [] of String
      @store.transactions.sort_by { |t| {t.date, t.id} }.reverse_each do |t|
        next if t.description.empty? || !seen.add?(t.description.downcase)
        out << t.description
        break if out.size >= limit
      end
      out
    end

    private def funding?(account : String) : Bool
      account.starts_with?("Assets") || account.starts_with?("Liabilities")
    end

    private def compare_recency(a : String, b : String, last_used : Hash(String, String)) : Int32
      la, lb = last_used[a]?, last_used[b]?
      return a <=> b if la.nil? && lb.nil?
      return 1 if la.nil?
      return -1 if lb.nil?
      (lb <=> la).zero? ? a <=> b : lb <=> la
    end

    # Human label for a recurring rule / due entry (memo, or the accounts, plus amount).
    def label(rule : RecurringRule) : String
      return "#{rule.description} (computed)" if rule.kind == "interest"
      label_for(rule.description, rule.postings)
    end

    def label(entry : DueEntry) : String
      label_for(entry.description, entry.postings)
    end
  end
end
