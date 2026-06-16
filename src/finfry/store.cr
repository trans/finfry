require "json"
require "./models"

module Finfry
  # Persists the `Database` to a single JSON file under the user's XDG data
  # directory (override with `FINFRY_DATA` for tests or alternate ledgers).
  class Store
    getter path : String
    getter db : Database

    def initialize(@path : String = Store.default_path)
      @db = load
    end

    def self.default_path : String
      if explicit = ENV["FINFRY_DATA"]?
        return explicit
      end

      base = ENV["XDG_DATA_HOME"]? || File.join(Path.home.to_s, ".local", "share")
      File.join(base, "finfry", "data.json")
    end

    private def load : Database
      return Database.new unless File.exists?(@path)
      Database.from_json(File.read(@path))
    rescue ex : JSON::ParseException
      raise Exception.new("ledger at #{@path} is corrupt: #{ex.message}")
    end

    def save : Nil
      Dir.mkdir_p(File.dirname(@path))
      File.write(@path, @db.to_pretty_json)
    end

    # --- mutations -------------------------------------------------------

    def add_transaction(date : String, amount : Int64, category : String,
                        description : String, kind : String) : Transaction
      txn = Transaction.new(@db.next_id, date, amount, category, description, kind)
      @db.next_id += 1
      @db.transactions << txn
      save
      txn
    end

    # Remove a transaction by id. Returns the deleted record, or nil if absent.
    def delete_transaction(id : Int32) : Transaction?
      index = @db.transactions.index { |t| t.id == id }
      return nil unless index
      txn = @db.transactions.delete_at(index)
      save
      txn
    end

    def set_budget(category : String, limit : Int64) : Nil
      @db.budgets[category] = limit
      save
    end

    def remove_budget(category : String) : Bool
      removed = @db.budgets.delete(category)
      save unless removed.nil?
      !removed.nil?
    end

    # --- queries ---------------------------------------------------------

    def transactions : Array(Transaction)
      @db.transactions
    end

    def budgets : Hash(String, Int64)
      @db.budgets
    end

    # Total expense (cents) for a category within a "YYYY-MM" month.
    def spent(category : String, month : String) : Int64
      @db.transactions.sum(0_i64) do |t|
        t.expense? && t.category == category && t.in_month?(month) ? t.amount : 0_i64
      end
    end
  end
end
