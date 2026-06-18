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

    @current_changeset : Changeset? = nil

    def initialize(@path : String = Store.default_path)
      @db = load
    end

    # The visible per-directory book file. finfry discovers it by walking up from
    # the current directory (like git's .git), so a project/folder can hold its
    # own ledger.
    BOOK_FILE = "finfry.json"

    # Resolve the active ledger: an explicit FINFRY_DATA override, else the
    # nearest book file walking up from the current directory, else the global
    # per-user ledger.
    def self.default_path : String
      ENV["FINFRY_DATA"]? || discover_book || global_path
    end

    # Nearest `finfry.json` at or above the current directory, or nil.
    def self.discover_book : String?
      dir = Dir.current
      loop do
        candidate = File.join(dir, BOOK_FILE)
        return candidate if File.exists?(candidate)
        parent = File.dirname(dir)
        break if parent == dir # reached the filesystem root
        dir = parent
      end
      nil
    end

    def self.global_path : String
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
      @current_changeset.try { |cs| cs.added_transaction_ids << txn.id }
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
      @current_changeset.try { |cs| cs.budget_changes << BudgetChange.new(account, @db.budgets[account]?) }
      @db.budgets[account] = limit
      save
    end

    # --- chart of accounts ----------------------------------------------

    def account_policy : String
      @db.account_policy
    end

    def set_account_policy(policy : String) : Nil
      @db.account_policy = policy
      save
    end

    # Declare an account in the chart. Returns false if already declared.
    def declare_account(name : String) : Bool
      return false if @db.accounts.includes?(name)
      @db.accounts << name
      @current_changeset.try { |cs| cs.declared_accounts << name }
      save
      true
    end

    # Remove an account from the chart. Returns false if it wasn't declared.
    # (If postings still reference it, it stays "known" via use.)
    def undeclare_account(name : String) : Bool
      removed = @db.accounts.delete(name)
      save unless removed.nil?
      !removed.nil?
    end

    # Rewrite every posting on `from` to `to` (also updating the chart and any
    # budget keyed on it). Doubles as a merge when `to` already exists. Returns
    # the number of postings rewritten.
    def rename_account(from : String, to : String) : Int32
      count = 0
      @db.transactions.each do |t|
        t.postings.map! do |p|
          if p.account == from
            count += 1
            Posting.new(to, p.amount)
          else
            p
          end
        end
      end

      if @db.accounts.delete(from)
        @db.accounts << to unless @db.accounts.includes?(to)
      end
      if limit = @db.budgets.delete(from)
        @db.budgets[to] = limit
      end

      save
      count
    end

    def remove_budget(account : String) : Bool
      removed = @db.budgets.delete(account)
      unless removed.nil?
        @current_changeset.try { |cs| cs.budget_changes << BudgetChange.new(account, removed) }
        save
      end
      !removed.nil?
    end

    # --- undo journal ----------------------------------------------------

    # Run a block as a single reversible changeset. Mutations inside record how
    # to undo themselves. Nested calls join the enclosing changeset, so an AI
    # plan's many operations collapse into one undo unit. The changeset is only
    # persisted if it actually changed something and the block didn't raise.
    def changeset(summary : String, at : String, & : -> T) : T forall T
      return yield if @current_changeset # nested → join the enclosing one

      @db.redo_snapshot = nil # a fresh action invalidates any pending redo
      cs = Changeset.new(0, at, summary)
      @current_changeset = cs
      result =
        begin
          yield
        ensure
          @current_changeset = nil
        end

      unless cs.empty?
        cs.id = @db.next_changeset_id
        @db.next_changeset_id += 1
        @db.changesets << cs
        save
      end
      result
    end

    def changesets : Array(Changeset)
      @db.changesets
    end

    # True if a reversing entry already undid changeset `id`.
    def reversed?(id : Int32) : Bool
      @db.changesets.any? { |c| c.reverses == id }
    end

    # Undo the most recent change by removing it outright — as if it never
    # happened. Safe precisely because it's the last change: nothing follows it.
    # Returns the removed changeset, or nil if there's nothing to undo.
    def undo_last : Changeset?
      cs = @db.changesets.last?
      return nil unless cs

      ids = cs.added_transaction_ids.to_set
      removed = @db.transactions.select { |t| ids.includes?(t.id) }
      redo_budgets = {} of String => Int64?
      cs.budget_changes.each { |ch| redo_budgets[ch.account] = @db.budgets[ch.account]? }

      @db.transactions.reject! { |t| ids.includes?(t.id) }
      @db.next_id = cs.added_transaction_ids.min unless cs.added_transaction_ids.empty?

      cs.budget_changes.each do |change|
        if previous = change.previous
          @db.budgets[change.account] = previous
        else
          @db.budgets.delete(change.account)
        end
      end

      used = used_accounts.to_set
      cs.declared_accounts.each { |a| @db.accounts.delete(a) unless used.includes?(a) }

      @db.changesets.pop
      @db.next_changeset_id -= 1 if cs.id == @db.next_changeset_id - 1
      @db.redo_snapshot = RedoSnapshot.new(cs, removed, redo_budgets)
      save
      cs
    end

    # Re-apply the change most recently removed by `undo_last`. Returns it, or
    # nil if there's nothing to redo.
    def redo_last : Changeset?
      snap = @db.redo_snapshot
      return nil unless snap

      snap.transactions.each { |t| @db.transactions << t }
      @db.next_id = (@db.transactions.map(&.id).max? || 0) + 1

      snap.budgets.each do |account, value|
        value ? (@db.budgets[account] = value) : @db.budgets.delete(account)
      end
      snap.changeset.declared_accounts.each { |a| @db.accounts << a unless @db.accounts.includes?(a) }

      @db.changesets << snap.changeset
      @db.next_changeset_id = snap.changeset.id + 1 if snap.changeset.id >= @db.next_changeset_id
      @db.redo_snapshot = nil
      save
      snap.changeset
    end

    # Correct an *older* change the proper accounting way: append a reversing
    # entry. The original is never removed — transactions it added are negated by
    # mirror-image postings, budget changes restored. Returns the reversing
    # changeset, nil if `id` is unknown, or raises if it's already reversed.
    def reverse(id : Int32, at : String, date : String) : Changeset?
      original = @db.changesets.find { |c| c.id == id }
      return nil unless original
      raise Error.new("change ##{id} is already reversed") if reversed?(id)
      @db.redo_snapshot = nil

      reversal = Changeset.new(0, at, "reverse ##{original.id}: #{original.summary}")
      reversal.reverses = original.id
      @current_changeset = reversal
      begin
        original.added_transaction_ids.each do |tid|
          orig = @db.transactions.find { |t| t.id == tid }
          next unless orig
          negated = orig.postings.map { |p| Posting.new(p.account, -p.amount) }
          record(date, "Reversal of ##{tid}", negated)
        end

        original.budget_changes.each do |change|
          if previous = change.previous
            set_budget(change.account, previous)
          else
            remove_budget(change.account)
          end
        end
      ensure
        @current_changeset = nil
      end

      reversal.id = @db.next_changeset_id
      @db.next_changeset_id += 1
      @db.changesets << reversal
      save
      reversal
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

    # Accounts explicitly declared in the chart.
    def declared_accounts : Array(String)
      @db.accounts
    end

    # Every distinct account a posting actually references, sorted.
    def used_accounts : Array(String)
      names = Set(String).new
      @db.transactions.each { |t| t.postings.each { |p| names << p.account } }
      names.to_a.sort
    end

    # Declared ∪ used — the accounts finfry treats as known. Feeds the AI's
    # chart context, the `accounts` listing, and completions.
    def known_accounts : Array(String)
      (@db.accounts + used_accounts).uniq.sort
    end

    def account_known?(name : String) : Bool
      @db.accounts.includes?(name) || used_accounts.includes?(name)
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
