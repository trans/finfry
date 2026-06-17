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

  # The full persisted state: an id counter, all transactions, per-account
  # monthly budget limits (cents), the declared chart of accounts, and the
  # unknown-account policy.
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

    # Brand-new ledger only — seeds the starter chart. from_json does not call
    # this, so deserialized ledgers keep whatever chart they had (or none).
    def initialize
      @accounts = DEFAULT_CHART.dup
    end
  end
end
