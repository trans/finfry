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

  # The full persisted state: an id counter, all transactions, and per-account
  # monthly budget limits (cents).
  class Database
    include JSON::Serializable

    property next_id : Int32 = 1
    property transactions : Array(Transaction) = [] of Transaction
    property budgets : Hash(String, Int64) = {} of String => Int64

    def initialize
    end
  end
end
