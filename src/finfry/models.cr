require "json"

module Finfry
  # A single recorded expense or income entry. Amounts are always stored as a
  # positive number of cents; `kind` distinguishes the direction.
  struct Transaction
    include JSON::Serializable

    getter id : Int32
    property date : String  # ISO date, "YYYY-MM-DD"
    property amount : Int64 # cents, always positive
    property category : String
    property description : String
    property kind : String # "expense" | "income"

    def initialize(@id, @date, @amount, @category, @description, @kind = "expense")
    end

    def expense? : Bool
      kind == "expense"
    end

    def income? : Bool
      kind == "income"
    end

    # Signed value: income is positive, expense negative. Useful for net totals.
    def signed_amount : Int64
      income? ? amount : -amount
    end

    # True if this transaction falls within the given "YYYY-MM" month.
    def in_month?(month : String) : Bool
      date.starts_with?(month)
    end
  end

  # The full persisted state of the app: an id counter, all transactions, and
  # per-category monthly budget limits (in cents).
  class Database
    include JSON::Serializable

    property next_id : Int32 = 1
    property transactions : Array(Transaction) = [] of Transaction
    property budgets : Hash(String, Int64) = {} of String => Int64

    def initialize
    end
  end
end
