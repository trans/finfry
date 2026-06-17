require "json"
require "./models"
require "./money"

module Finfry
  # Persists the `Database` to a single JSON file under the user's XDG data
  # directory (override with `FINFRY_DATA`). Writes are atomic (temp file +
  # rename) so a crash mid-write can't corrupt the ledger. Legacy single-entry
  # files are migrated to double-entry on load, keeping a `.bak` backup.
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

      raw = JSON.parse(File.read(@path))
      if legacy?(raw)
        backup!
        db = migrate(raw)
        write(db)
        db
      else
        Database.from_json(raw.to_json)
      end
    rescue ex : JSON::ParseException
      raise Error.new("ledger at #{@path} is corrupt: #{ex.message}")
    end

    # --- persistence -----------------------------------------------------

    def save : Nil
      write(@db)
    end

    private def write(db : Database) : Nil
      Dir.mkdir_p(File.dirname(@path))
      tmp = "#{@path}.tmp"
      File.write(tmp, db.to_pretty_json)
      File.rename(tmp, @path) # atomic on the same filesystem
    end

    private def backup! : Nil
      File.copy(@path, "#{@path}.bak")
    end

    # --- legacy migration ------------------------------------------------

    # Old format stored each transaction with flat `amount`/`category`/`kind`
    # fields and no `postings`.
    private def legacy?(raw : JSON::Any) : Bool
      first = raw["transactions"]?.try(&.as_a?).try(&.first?).try(&.as_h?)
      return false unless first
      first.has_key?("kind") && !first.has_key?("postings")
    end

    private def migrate(raw : JSON::Any) : Database
      db = Database.new
      db.next_id = raw["next_id"]?.try(&.as_i?) || 1

      raw["transactions"].as_a.each do |t|
        amount = t["amount"].as_i64
        category = t["category"].as_s
        postings =
          if t["kind"].as_s == "income"
            [Posting.new(DEFAULT_ASSET_ACCOUNT, amount), Posting.new("Income:#{category}", -amount)]
          else
            [Posting.new("Expenses:#{category}", amount), Posting.new(DEFAULT_ASSET_ACCOUNT, -amount)]
          end
        db.transactions << Transaction.new(t["id"].as_i, t["date"].as_s, t["description"].as_s, postings)
      end

      raw["budgets"]?.try(&.as_h?).try &.each do |category, limit|
        db.budgets["Expenses:#{category}"] = limit.as_i64
      end

      db
    end

    # --- mutations -------------------------------------------------------

    # Build, validate, persist, and return a transaction. Raises `Error` if the
    # postings don't balance.
    def record(date : String, description : String, postings : Array(Posting),
               recurrence : String? = nil) : Transaction
      txn = Transaction.new(@db.next_id, date, description, postings, recurrence)
      unless txn.balanced?
        raise Error.new("postings do not balance (off by #{Money.format(txn.imbalance)})")
      end

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

    def set_budget(account : String, limit : Int64) : Nil
      @db.budgets[account] = limit
      save
    end

    def remove_budget(account : String) : Bool
      removed = @db.budgets.delete(account)
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

    # Net balance of every account (optionally restricted to a subtree, and/or
    # to transactions on or before `up_to`). Returns account => signed cents.
    def balances(prefix : String? = nil, up_to : String? = nil) : Hash(String, Int64)
      result = Hash(String, Int64).new(0_i64)
      @db.transactions.each do |t|
        next if up_to && t.date > up_to
        t.postings.each do |p|
          next if prefix && !Finfry.in_subtree?(p.account, prefix)
          result[p.account] += p.amount
        end
      end
      result
    end

    # Every distinct account name ever used, sorted. Feeds completions and (later)
    # the AI's chart-of-accounts context.
    def accounts : Array(String)
      names = Set(String).new
      @db.transactions.each { |t| t.postings.each { |p| names << p.account } }
      names.to_a.sort
    end

    # Net movement into an account subtree within a "YYYY-MM" month. For an
    # Expenses account this is the amount spent.
    def spent(account : String, month : String) : Int64
      @db.transactions.sum(0_i64) do |t|
        next 0_i64 unless t.in_month?(month)
        t.postings.sum(0_i64) { |p| Finfry.in_subtree?(p.account, account) ? p.amount : 0_i64 }
      end
    end
  end
end
