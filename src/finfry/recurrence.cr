require "./models"

module Finfry
  # Maps a recurrence cadence to a per-day cost. We pay on a cadence (monthly,
  # yearly, …) but want to see the cost *amortized per day* — derived purely from
  # the cadence, not from accrual bookkeeping.
  module Recurrence
    # Average days per period. Months/quarters/years use 365.25/N so leap years
    # and uneven month lengths wash out.
    DAYS = {
      "daily"     => 1.0,
      "weekly"    => 7.0,
      "biweekly"  => 14.0,
      "monthly"   => 365.25 / 12,
      "quarterly" => 365.25 / 4,
      "yearly"    => 365.25,
    }

    AVG_MONTH = 365.25 / 12
    AVG_YEAR  = 365.25

    # Cadence names, in ascending period length (for help text / enums).
    def self.names : Array(String)
      ["daily", "weekly", "biweekly", "monthly", "quarterly", "yearly"]
    end

    def self.valid?(name : String) : Bool
      DAYS.has_key?(name)
    end

    def self.days(name : String) : Float64
      DAYS[name]? || raise Error.new("unknown recurrence #{name.inspect} (one of: #{names.join(", ")})")
    end

    # Per-day cost in (fractional) cents for an amount paid on this cadence.
    def self.per_day(cents : Int64, name : String) : Float64
      cents / days(name)
    end
  end

  # One recurring commitment, reduced to its current per-day cost.
  struct RecurringItem
    getter label : String
    getter recurrence : String
    getter amount : Int64 # positive magnitude per period
    getter kind : Symbol  # :expense | :income

    def initialize(@label, @recurrence, @amount, @kind)
    end

    def expense? : Bool
      kind == :expense
    end

    def income? : Bool
      kind == :income
    end

    def per_day : Float64
      Recurrence.per_day(amount, recurrence)
    end
  end

  # Reduce a set of transactions to current recurring commitments. Each recurring
  # stream is identified by its description (or, if blank, its income/expense
  # accounts), and only the most recent occurrence in a stream counts — so
  # recording Netflix every month yields one Netflix commitment, not twelve.
  def self.recurring_items(transactions : Array(Transaction)) : Array(RecurringItem)
    latest = {} of String => Transaction
    transactions.each do |t|
      next unless t.recurrence
      key = stream_key(t)
      current = latest[key]?
      latest[key] = t if current.nil? || t.date >= current.date
    end

    items = [] of RecurringItem
    latest.each_value do |t|
      cadence = t.recurrence.not_nil!
      expense = t.postings.sum(0_i64) { |p| p.account.starts_with?("Expenses") ? p.amount : 0_i64 }
      income = t.postings.sum(0_i64) { |p| p.account.starts_with?("Income") ? -p.amount : 0_i64 }
      label = t.description.empty? ? stream_key(t) : t.description

      if expense > 0
        items << RecurringItem.new(label, cadence, expense, :expense)
      elsif income > 0
        items << RecurringItem.new(label, cadence, income, :income)
      end
    end

    items.sort_by { |i| -i.per_day }
  end

  # Stream identity: the description if present, else the non-asset/liability
  # accounts it touches.
  private def self.stream_key(t : Transaction) : String
    return t.description.downcase unless t.description.empty?
    t.postings
      .map(&.account)
      .reject { |a| a.starts_with?("Assets") || a.starts_with?("Liabilities") }
      .sort
      .join("+")
  end
end
