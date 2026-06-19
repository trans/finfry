require "json"

module Finfry
  # Default account money is paid from / received into when not specified.
  DEFAULT_ASSET_ACCOUNT = "Assets:Checking"

  # Raised for user-facing domain errors (unbalanced postings, etc.).
  class Error < Exception
  end

  # True if `account` is `prefix` itself or a descendant of it. Accounts are
  # hierarchical, colon-separated ("Expenses:Food:Coffee"), so a prefix match
  # must respect the ":" boundary — "Expenses:Foodie" is not under "Expenses:Food".
  def self.in_subtree?(account : String, prefix : String) : Bool
    account == prefix || account.starts_with?("#{prefix}:")
  end

  # Build the balanced posting pair for a kind of transaction. `account` is the
  # categorization account (Expenses/Income, or the destination of a transfer);
  # `counter` is the money account (the asset/liability paid from or received
  # into, or the source of a transfer). Both the CLI commands and the AI entry
  # path funnel through here so balance is always assembled the same way.
  def self.postings_for(kind : String, amount : Int64, account : String, counter : String) : Array(Posting)
    case kind
    when "expense", "transfer"
      [Posting.new(account, amount), Posting.new(counter, -amount)]
    when "income"
      [Posting.new(counter, amount), Posting.new(account, -amount)]
    else
      raise Error.new("unknown transaction kind #{kind.inspect}")
    end
  end

  # One leg of a double-entry transaction: a signed amount applied to an account.
  struct Posting
    include JSON::Serializable

    property account : String
    property amount : Int64 # signed cents

    def initialize(@account, @amount)
    end
  end

  # A double-entry transaction: a dated, described set of postings whose signed
  # amounts must sum to zero.
  struct Transaction
    include JSON::Serializable

    getter id : Int32
    property date : String # YYYY-MM-DD
    property description : String
    property postings : Array(Posting)

    # Cadence this transaction recurs on (e.g. "monthly"), or nil for one-offs.
    # Used only for per-day amortization, not for auto-posting.
    @[JSON::Field(emit_null: false)]
    property recurrence : String? = nil

    def initialize(@id, @date, @description, @postings, @recurrence = nil)
    end

    # Sum of all posting amounts; zero for a balanced transaction.
    def imbalance : Int64
      postings.sum(&.amount)
    end

    def balanced? : Bool
      imbalance.zero?
    end

    # True if any posting touches `account` or one of its descendants.
    def touches?(account : String) : Bool
      postings.any? { |p| Finfry.in_subtree?(p.account, account) }
    end

    def in_month?(month : String) : Bool
      date.starts_with?(month)
    end
  end

  # Starter chart seeded into a brand-new ledger so strict mode is usable
  # immediately. Existing ledgers are unaffected — `Database.from_json` falls
  # back to the empty property default, and their known accounts come from the
  # postings already recorded.
  DEFAULT_CHART = %w[
    Assets:Checking
    Assets:Cash
    Liabilities:CreditCard
    Income:Salary
    Expenses:Food
    Expenses:Housing
    Expenses:Transport
    Expenses:Health
    Expenses:Entertainment
    Expenses:Misc
  ]

  # How finfry reacts to a posting naming an account that isn't yet "known"
  # (declared in the chart or already used by a posting).
  ACCOUNT_POLICIES = %w[strict guard off]

  # A point-in-time balance sheet: accounts sectioned into Assets / Liabilities /
  # Equity (each as {account, display_amount} with credit-normal sides flipped to
  # read positive), plus net income (Income − Expenses) folded into equity. Since
  # every transaction balances, a non-zero `discrepancy` means tampered data.
  struct BalanceSheet
    getter assets : Array({String, Int64})
    getter liabilities : Array({String, Int64})
    getter equity : Array({String, Int64})
    getter net_income : Int64

    def initialize(@assets, @liabilities, @equity, @net_income)
    end

    def total_assets : Int64
      @assets.sum(0_i64) { |e| e[1] }
    end

    def total_liabilities : Int64
      @liabilities.sum(0_i64) { |e| e[1] }
    end

    def total_equity : Int64
      @equity.sum(0_i64) { |e| e[1] } + @net_income
    end

    # Assets − (Liabilities + Equity). Zero for valid data.
    def discrepancy : Int64
      total_assets - total_liabilities - total_equity
    end

    def balanced? : Bool
      discrepancy.zero?
    end
  end

  # Build a balance sheet from raw account balances (account => signed cents).
  def self.balance_sheet(balances : Hash(String, Int64)) : BalanceSheet
    section = ->(prefix : String, flip : Bool) do
      balances
        .select { |account, _| account == prefix || account.starts_with?("#{prefix}:") }
        .map { |account, value| {account, flip ? -value : value} }
        .reject { |entry| entry[1].zero? }
        .sort_by { |entry| entry[0] }
    end

    income = balances.sum(0_i64) { |(a, v)| a == "Income" || a.starts_with?("Income:") ? -v : 0_i64 }
    expenses = balances.sum(0_i64) { |(a, v)| a == "Expenses" || a.starts_with?("Expenses:") ? v : 0_i64 }

    BalanceSheet.new(section.call("Assets", false), section.call("Liabilities", true), section.call("Equity", true), income - expenses)
  end

  # One budget value before a changeset altered it. `previous` is nil when the
  # account had no budget (so undo removes the key rather than restoring a value).
  struct BudgetChange
    include JSON::Serializable

    property account : String
    property previous : Int64?

    def initialize(@account, @previous)
    end
  end

  # A reversible unit of work — one manual command, or one approved AI plan.
  # Records exactly what it changed so it can be undone. The ledger is an
  # append-only set of independent, self-balancing transactions, so removing the
  # transactions a changeset added never unbalances anything that came after.
  struct Changeset
    include JSON::Serializable

    property id : Int32
    property at : String      # timestamp, "YYYY-MM-DD HH:MM"
    property summary : String # human-readable label

    # If set, this changeset is the reversing entry that undid changeset N.
    property reverses : Int32? = nil

    property added_transaction_ids : Array(Int32) = [] of Int32
    property budget_changes : Array(BudgetChange) = [] of BudgetChange
    property declared_accounts : Array(String) = [] of String

    def initialize(@id, @at, @summary)
    end

    def reversal? : Bool
      !reverses.nil?
    end

    def empty? : Bool
      added_transaction_ids.empty? && budget_changes.empty? && declared_accounts.empty?
    end
  end

  # Enough to re-apply a change that `undo` removed. `budgets` maps each touched
  # account to the value to restore (nil = the change had set no budget / removed
  # it). Single-slot: only the most recently popped change can be redone.
  struct RedoSnapshot
    include JSON::Serializable

    property changeset : Changeset
    property transactions : Array(Transaction)
    property budgets : Hash(String, Int64?)

    def initialize(@changeset, @transactions, @budgets)
    end
  end

  # The full persisted state: an id counter, all transactions, per-account
  # monthly budget limits (cents), the declared chart of accounts, the
  # unknown-account policy, and the undo journal.
  class Database
    include JSON::Serializable

    property next_id : Int32 = 1
    property transactions : Array(Transaction) = [] of Transaction
    property budgets : Hash(String, Int64) = {} of String => Int64

    # Explicitly declared accounts (the chart). Empty by default so existing
    # ledgers loaded via from_json aren't reseeded.
    property accounts : Array(String) = [] of String

    # "strict" | "guard" | "off"
    property account_policy : String = "strict"

    # Undo journal — one entry per mutating operation, newest last.
    property changesets : Array(Changeset) = [] of Changeset
    property next_changeset_id : Int32 = 1

    # The last change removed by `undo`, available for `redo` until the next
    # mutation invalidates it.
    property redo_snapshot : RedoSnapshot? = nil

    # Brand-new ledger only — seeds the starter chart. from_json does not call
    # this, so deserialized ledgers keep whatever chart they had (or none).
    def initialize
      @accounts = DEFAULT_CHART.dup
    end
  end
end
