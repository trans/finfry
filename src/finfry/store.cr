require "json"
require "keep"
require "./models"
require "./money"

module Finfry
  # The book's store. The truth is an append-only log of commits
  # (`finfry.log`, a `Keep::Log`); the `Database` held here is the fold of that
  # log, and `finfry.json` is a checkpoint of the fold as of some commit —
  # regenerable at any time. Every mutation is an *action*: it is applied to
  # the in-memory state and appended to the log by the same `apply`, so the
  # fold and the live state can't disagree.
  #
  # Mutations made inside `changeset` become one commit (kind `ledger`);
  # made outside, each becomes its own commit (kind `bookkeeping`). Undo is a
  # revert mark on the log — nothing is ever deleted.
  #
  # An older `finfry.json` (no log beside it) is migrated on first open: its
  # journal becomes commits, the rest of its state one `migrated` commit, and
  # the original is kept as `finfry.json.pre-log`.
  class Store
    getter path : String
    getter db : Database
    getter log : Keep::Log

    # Where commits are attributed to: cli, web, mcp, ai.
    property origin : String = "cli"

    # The commit sequence the in-memory state is folded to.
    getter version : Int64 = 0

    # Commit kinds. `history` shows ledger commits; bookkeeping ones (cleared
    # marks, due staging, rules, metadata) are there with `--all`.
    KIND_LEDGER      = "ledger"
    KIND_BOOKKEEPING = "bookkeeping"

    # An open commit: actions accumulate here until the `changeset` block ends.
    private record Pending, summary : String, at : String, kind : String, actions : Array(Keep::Action)

    @pending : Pending? = nil

    # A brand-new book has its starter chart in memory but nothing on disk
    # yet; the chart is written as the log's first commit when the book is.
    @needs_starter = false

    def initialize(@path : String = Store.default_path)
      @log = Keep::Log.new(Store.log_path(@path))
      @db = Database.new
      open!
    end

    # --- paths ----------------------------------------------------------

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

    # The log that goes with a checkpoint: same base name, `.log`.
    def self.log_path(path : String) : String
      path.ends_with?(".json") ? path.rchop(".json") + ".log" : path + ".log"
    end

    # --- opening ----------------------------------------------------------

    # Load the checkpoint (if any) and fold the log past it. A checkpoint
    # that isn't one (an older finfry.json) is migrated into a log first.
    private def open! : Nil
      if !File.exists?(@log.path) && File.exists?(@path)
        migrate_to_log!
      end
      unless File.exists?(@log.path)
        @db.accounts = DEFAULT_CHART.dup
        @needs_starter = true
        return
      end
      @log = Keep::Log.open(@log.path)

      checkpoint = Keep::Checkpoint.read(@path) rescue nil
      if checkpoint && !@log.replay_needed?(checkpoint[0])
        @version, state = checkpoint
        @db = Database.from_json(state)
      else
        @db = Database.new
        @version = 0
      end
      fold!
    end

    # Apply every commit past `@version` (or everything, after a revert that
    # reaches back), then refresh the checkpoint if it was behind.
    private def fold! : Nil
      if @log.replay_needed?(@version)
        @db = Database.new
        @version = 0
      end
      before = @version
      @log.each_commit(after: @version) do |c|
        @version = c.seq
        next if c.mark?
        c.actions.each { |a| Store.apply(@db, a, reverted: c.reverted?) }
      end
      checkpoint! if @version != before
    end

    # Pick up commits another process appended (the CLI or MCP alongside
    # `serve`). Returns true if anything new was folded in.
    def refresh : Bool
      return false unless File.exists?(@log.path)
      latest = @log.version
      return false if latest == @version && !@log.replay_needed?(@version)
      fold!
      true
    end

    private def checkpoint! : Nil
      Keep::Checkpoint.write(@path, @version, @db.to_json)
    end

    # Make sure the book exists on disk (its log and checkpoint), e.g. `init`.
    def touch : Nil
      starter! if @needs_starter
      @log = Keep::Log.open(@log.path)
      checkpoint!
    end

    # The first commit of a new book: the starter chart, as declarations.
    private def starter! : Nil
      @needs_starter = false
      @log = Keep::Log.open(@log.path)
      c = @log.append(at: now, origin: @origin, kind: KIND_BOOKKEEPING, summary: "starter chart") do |b|
        DEFAULT_CHART.each { |a| b.action("declare", a) }
      end
      @version = c.seq
      checkpoint!
    end

    # --- committing ---------------------------------------------------------

    # Run a block as one commit. Nested calls join the enclosing one, so an AI
    # plan's many operations collapse into one undo unit. Nothing is written if
    # the block changed nothing or raised.
    def changeset(summary : String, at : String, kind : String = KIND_LEDGER, & : -> T) : T forall T
      return yield if @pending

      @pending = Pending.new(summary, at, kind, [] of Keep::Action)
      begin
        result = yield
      rescue ex
        @pending = nil
        refresh_after_abort!
        raise ex
      end
      pending = @pending.not_nil!
      @pending = nil
      commit!(pending) unless pending.actions.empty?
      result
    end

    # A mutation's single point of truth: apply it to the live state and queue
    # it for the log — inside a changeset, into that commit; outside, as a
    # bookkeeping commit of its own.
    private def emit(summary : String, action : Keep::Action) : Nil
      Store.apply(@db, action)
      if p = @pending
        p.actions << action
      else
        commit!(Pending.new(summary, now, KIND_BOOKKEEPING, [action]))
      end
    end

    private def commit!(p : Pending) : Nil
      starter! if @needs_starter
      @log.lock do
        # Someone else may have appended since we folded: catch up first, so
        # our seq follows theirs and our state includes their effects.
        fold! if @log.version != @version
        c = @log.append(at: p.at, origin: @origin, kind: p.kind, summary: p.summary) do |b|
          p.actions.each { |a| b.action(a.name, a.fields) }
        end
        @version = c.seq
        checkpoint!
      end
    end

    # A changeset that raised has half-applied actions in memory; rebuild from
    # the log so the live state matches the truth again.
    private def refresh_after_abort! : Nil
      @db = Database.new
      @version = 0
      fold!
    end

    private def now : String
      Time.local.to_s("%Y-%m-%d %H:%M")
    end

    # --- the fold -----------------------------------------------------------

    # Apply one action to a database. Used for the live state and for replay,
    # so it is the definition of what each action *means*. For a reverted
    # commit only the id counters advance (`reverted: true`), so ids are never
    # reused even after an undo.
    def self.apply(db : Database, a : Keep::Action, reverted : Bool = false) : Nil
      case a.name
      when "record"
        id = a[0].to_i
        db.next_id = {db.next_id, id + 1}.max
        return if reverted
        txn = Transaction.new(id, a[1], a[2], postings_of(a.list(4)), a[3]?)
        insert_by_id(db.transactions, txn)
      when "rule"
        id = a[0].to_i
        db.next_recurring_id = {db.next_recurring_id, id + 1}.max
        return if reverted
        db.recurring << RecurringRule.new(id, a[1], a[2], a[3], postings_of(a.list(6)), a[4], a[5] == "true")
      when "due"
        id = a[0].to_i
        db.next_due_id = {db.next_due_id, id + 1}.max
        return if reverted
        db.due_entries << DueEntry.new(id, a[1].to_i, a[2], a[3], postings_of(a.list(6)), a[4], a[5])
      else
        return if reverted
        apply_plain(db, a)
      end
    end

    private def self.apply_plain(db : Database, a : Keep::Action) : Nil
      case a.name
      when "reverses"  then nil # provenance only: this commit reverses commit a[0]
      when "remove"    then db.transactions.reject! { |t| t.id == a[0].to_i }
      when "budget"    then db.budgets[a[0]] = a[1].to_i64
      when "unbudget"  then db.budgets.delete(a[0])
      when "declare"   then db.accounts << a[0] unless db.accounts.includes?(a[0])
      when "undeclare" then db.accounts.delete(a[0])
      when "rename"    then rename(db, a[0], a[1])
      when "meta"      then (db.account_meta[a[0]] ||= {} of String => String)[a[1]] = a[2]
      when "unmeta"
        if meta = db.account_meta[a[0]]?
          meta.delete(a[1])
          db.account_meta.delete(a[0]) if meta.empty?
        end
      when "setting"
        case a[0]
        when "policy"  then db.account_policy = a[1]
        when "example" then db.example = a[1] == "true"
        end
      when "clear"
        list = (db.cleared[a[0]] ||= [] of Int32)
        a.list(1).each { |s| id = s.to_i; list << id unless list.includes?(id) }
      when "unclear"
        if list = db.cleared[a[0]]?
          ids = a.list(1).map(&.to_i)
          list.reject! { |id| ids.includes?(id) }
          db.cleared.delete(a[0]) if list.empty?
        end
      when "reconcile"
        ids = a.list(4).map(&.to_i)
        committed = (db.reconciled[a[0]] ||= [] of Int32)
        ids.each { |id| committed << id unless committed.includes?(id) }
        db.reconciliations << Reconciliation.new(a[0], a[2], a[1].to_i64, ids, a[3]?)
        if staged = db.cleared[a[0]]?
          staged.reject! { |id| ids.includes?(id) }
          db.cleared.delete(a[0]) if staged.empty?
        end
      when "rule-off"  then db.recurring.find { |r| r.id == a[0].to_i }.try(&.active = false)
      when "rule-next" then db.recurring.find { |r| r.id == a[0].to_i }.try(&.next_date = a[1])
      when "due-status"
        ids = a.list(0).map(&.to_i)
        db.due_entries.each { |e| e.status = a[1] if ids.includes?(e.id) }
      when "due-edit"
        if e = db.due_entries.find { |e| e.id == a[0].to_i }
          e.date = a[1]
          e.description = a[2]
          e.postings = postings_of(a.list(3))
          e.status = a[4]
        end
      when "due-remove"
        ids = a.list(0).map(&.to_i)
        db.due_entries.reject! { |e| ids.includes?(e.id) }
      else
        raise Error.new("unknown action #{a.name.inspect} in the log")
      end
    end

    private def self.rename(db : Database, from : String, to : String) : Nil
      db.transactions.each do |t|
        t.postings.map! { |p| p.account == from ? Posting.new(to, p.amount) : p }
      end
      if db.accounts.delete(from)
        db.accounts << to unless db.accounts.includes?(to)
      end
      if limit = db.budgets.delete(from)
        db.budgets[to] = limit
      end
      if meta = db.account_meta.delete(from)
        target = db.account_meta[to] ||= {} of String => String
        meta.each { |key, value| target[key] = value unless target.has_key?(key) }
      end
    end

    # Postings travel as a flat list: account, cents, account, cents, …
    def self.postings_of(flat : Array(String)) : Array(Posting)
      flat.each_slice(2).map { |(account, cents)| Posting.new(account, cents.to_i64) }.to_a
    end

    def self.flat(postings : Array(Posting)) : Array(String)
      postings.flat_map { |p| [p.account, p.amount.to_s] }
    end

    # Keep `transactions` in id order however commits interleave.
    private def self.insert_by_id(list : Array(Transaction), txn : Transaction) : Nil
      i = list.bsearch_index { |t| t.id > txn.id } || list.size
      list.insert(i, txn)
    end

    # --- mutations ----------------------------------------------------------

    # Build, validate, persist, and return a transaction. Raises `Error` if the
    # postings don't balance.
    def record(date : String, description : String, postings : Array(Posting),
               recurrence : String? = nil) : Transaction
      txn = Transaction.new(@db.next_id, date, description, postings, recurrence)
      unless txn.balanced?
        raise Error.new("postings do not balance (off by #{Money.format(txn.imbalance)})")
      end
      emit("record ##{txn.id}", Keep::Action.new("record", txn.id, date, description, recurrence, Store.flat(postings)))
      txn
    end

    # Remove a transaction by id. Returns the deleted record, or nil if absent.
    def delete_transaction(id : Int32) : Transaction?
      txn = @db.transactions.find { |t| t.id == id }
      return nil unless txn
      emit("delete ##{id}", Keep::Action.new("remove", id))
      txn
    end

    def set_budget(account : String, limit : Int64) : Nil
      emit("budget #{account}", Keep::Action.new("budget", account, limit))
    end

    def remove_budget(account : String) : Bool
      return false unless @db.budgets.has_key?(account)
      emit("remove budget #{account}", Keep::Action.new("unbudget", account))
      true
    end

    # --- chart of accounts ----------------------------------------------

    def example? : Bool
      @db.example
    end

    def mark_example(flag : Bool = true) : Nil
      emit("example book", Keep::Action.new("setting", "example", flag.to_s))
    end

    def account_policy : String
      @db.account_policy
    end

    def set_account_policy(policy : String) : Nil
      emit("policy #{policy}", Keep::Action.new("setting", "policy", policy))
    end

    # Declare an account in the chart. Returns false if already declared.
    def declare_account(name : String) : Bool
      return false if @db.accounts.includes?(name)
      emit("declare #{name}", Keep::Action.new("declare", name))
      true
    end

    # Remove an account from the chart. Returns false if it wasn't declared.
    # (If postings still reference it, it stays "known" via use.)
    def undeclare_account(name : String) : Bool
      return false unless @db.accounts.includes?(name)
      emit("undeclare #{name}", Keep::Action.new("undeclare", name))
      true
    end

    # Rewrite every posting on `from` to `to` (also updating the chart and any
    # budget keyed on it). Doubles as a merge when `to` already exists. Returns
    # the number of postings rewritten.
    def rename_account(from : String, to : String) : Int32
      count = @db.transactions.sum { |t| t.postings.count { |p| p.account == from } }
      emit("rename #{from} → #{to}", Keep::Action.new("rename", from, to))
      count
    end

    # --- account metadata -----------------------------------------------

    def account_meta(account : String) : Hash(String, String)
      @db.account_meta[account]? || {} of String => String
    end

    def set_account_meta(account : String, key : String, value : String) : Nil
      emit("#{account} #{key}", Keep::Action.new("meta", account, key, value))
    end

    # Remove a metadata key. Returns false if it wasn't set.
    def unset_account_meta(account : String, key : String) : Bool
      return false unless @db.account_meta[account]?.try(&.has_key?(key))
      emit("#{account} unset #{key}", Keep::Action.new("unmeta", account, key))
      true
    end

    # --- recurring rules ------------------------------------------------

    def recurring_rules : Array(RecurringRule)
      @db.recurring
    end

    def add_recurring_rule(description : String, cadence : String, start_date : String, postings : Array(Posting), kind : String = "fixed") : RecurringRule
      id = @db.next_recurring_id
      emit("recurring ##{id}", Keep::Action.new("rule", id, description, cadence, start_date, kind, "true", Store.flat(postings)))
      @db.recurring.find { |r| r.id == id }.not_nil!
    end

    def deactivate_rule(id : Int32) : Bool
      return false unless @db.recurring.any? { |r| r.id == id }
      emit("recurring ##{id} off", Keep::Action.new("rule-off", id))
      true
    end

    # How many occurrences `generate_due` would materialize as of `today`,
    # without touching anything — so a read-only view can say "N new have
    # come due" and offer the catch-up as a deliberate step.
    def occurrences_due(today : String) : Int32
      @db.recurring.sum(0) do |rule|
        rule.active ? Recurrence.occurrences(rule.next_date, rule.cadence, today).size : 0
      end
    end

    # Materialize every occurrence due up to `today` into the queue, advancing
    # each rule's cursor so nothing is generated twice. What was generated —
    # including a computed interest charge — is what's logged, so replay never
    # recomputes it. Returns how many were added.
    def generate_due(today : String) : Int32
      count = 0
      changeset("due: catch up to #{today}", now, KIND_BOOKKEEPING) do
        generate_due_actions(today) { count += 1 }
      end
      count
    end

    private def generate_due_actions(today : String, & : ->) : Nil
      @db.recurring.each do |rule|
        next unless rule.active
        dates = Recurrence.occurrences(rule.next_date, rule.cadence, today)
        next if dates.empty?
        dates.each do |date|
          postings = rule.kind == "interest" ? interest_postings(rule, date) : rule.postings.dup
          next if postings.nil? # interest couldn't be computed (no APR / nothing owed) → skip this cycle
          id = @db.next_due_id
          emit("due ##{id}", Keep::Action.new("due", id, rule.id, date, rule.description, rule.cadence, "pending", Store.flat(postings)))
          yield
        end
        emit("recurring ##{rule.id} next", Keep::Action.new("rule-next", rule.id, Recurrence.advance(dates.last, rule.cadence)))
      end
    end

    # A computed charge: the card's APR (account metadata) applied to what's
    # owed on `date`, for one cadence's slice of the year. Nil if there's no
    # APR or nothing owed.
    private def interest_postings(rule : RecurringRule, date : String) : Array(Posting)?
      card = rule.postings.find { |p| p.account.starts_with?("Liabilities") }
      interest = rule.postings.find { |p| !p.account.starts_with?("Liabilities") }
      return nil unless card && interest

      apr = account_meta(card.account)["apr"]?.try(&.to_f?)
      return nil unless apr

      owed = -(balances(up_to: date)[card.account]? || 0_i64)
      return nil if owed <= 0

      rate = apr / 100.0 * Recurrence.days(rule.cadence) / 365.25
      cents = (owed * rate).round.to_i64
      return nil if cents <= 0

      Finfry.postings_for("expense", cents, interest.account, card.account)
    end

    def due_entries : Array(DueEntry)
      @db.due_entries
    end

    def set_due_status(ids : Array(Int32), status : String) : Nil
      return if ids.empty?
      emit("due #{status}: #{ids.join(", ")}", Keep::Action.new("due-status", ids, status))
    end

    # Adjust an entry before posting; it's marked ok.
    def edit_due(id : Int32, date : String, description : String, postings : Array(Posting)) : Nil
      emit("due ##{id} edited", Keep::Action.new("due-edit", id, date, description, Store.flat(postings), "ok"))
    end

    def remove_due_entries(ids : Array(Int32)) : Nil
      return if ids.empty?
      emit("due resolved: #{ids.join(", ")}", Keep::Action.new("due-remove", ids))
    end

    # --- reconciliation ---------------------------------------------------

    # Transaction ids marked cleared against `account`'s statement.
    def cleared_ids(account : String) : Array(Int32)
      @db.cleared[account]? || [] of Int32
    end

    def cleared?(account : String, id : Int32) : Bool
      cleared_ids(account).includes?(id)
    end

    # Mark (or unmark) transactions as cleared against `account`. Returns the
    # number of ids whose state actually changed.
    def set_cleared(account : String, ids : Array(Int32), cleared : Bool) : Int32
      current = cleared_ids(account)
      changed = cleared ? ids.reject { |id| current.includes?(id) } : ids.select { |id| current.includes?(id) }
      return 0 if changed.empty?
      verb = cleared ? "clear" : "unclear"
      emit("#{verb} #{account}: #{changed.join(", ")}", Keep::Action.new(verb, account, changed))
      changed.size
    end

    # Committed (reconciled) tier.
    def reconciled_ids(account : String) : Array(Int32)
      @db.reconciled[account]? || [] of Int32
    end

    def reconciled?(account : String, id : Int32) : Bool
      reconciled_ids(account).includes?(id)
    end

    # Net of `account`'s own postings (exact match — a statement reconciles one
    # account, not a subtree) across the transactions in `ids`. A id with no
    # surviving transaction is ignored, so stale ids are harmless.
    private def balance_of(account : String, ids : Array(Int32)) : Int64
      set = ids.to_set
      @db.transactions.sum(0_i64) do |t|
        next 0_i64 unless set.includes?(t.id)
        t.postings.sum(0_i64) { |p| p.account == account ? p.amount : 0_i64 }
      end
    end

    # Balance of the staged tier (cleared-but-not-committed).
    def cleared_balance(account : String) : Int64
      balance_of(account, cleared_ids(account))
    end

    # Balance of the committed tier (locked by past reconciliations).
    def reconciled_balance(account : String) : Int64
      balance_of(account, reconciled_ids(account))
    end

    # Finalize a reconciliation: move every staged-cleared transaction into the
    # committed tier and record the statement it was balanced against. The
    # caller verifies the balance matches first. Returns the number locked in.
    def reconcile!(account : String, statement : Int64, date : String, statement_date : String? = nil) : Int32
      staged = cleared_ids(account).dup
      return 0 if staged.empty?
      emit("reconcile #{account} #{Money.format(statement)}",
        Keep::Action.new("reconcile", account, statement, date, statement_date, staged))
      staged.size
    end

    # The most recent finalized reconciliation for an account, if any.
    def last_reconciliation(account : String) : Reconciliation?
      @db.reconciliations.reverse_each.find { |r| r.account == account }
    end

    # Every finalized reconciliation for an account, oldest first.
    def reconciliations(account : String) : Array(Reconciliation)
      @db.reconciliations.select { |r| r.account == account }
    end

    # --- history: the ledger commits, as changesets ---------------------------

    # Ledger commits (what `history` shows), oldest first, as `Changeset`
    # views: id = the commit's sequence number. With `all`, every commit —
    # bookkeeping (cleared marks, due staging, rules, metadata) and the undo
    # marks themselves — so the log can be read end to end.
    def changesets(all : Bool = false) : Array(Changeset)
      @log.commits.compact_map { |c| changeset_view(c, all) }
    end

    private def changeset_view(c : Keep::Commit, all : Bool = false) : Changeset?
      return nil unless all || (!c.mark? && c.kind == KIND_LEDGER)
      cs = Changeset.new(c.seq.to_i32, c.at, c.summary)
      cs.kind = c.mark? ? "mark" : c.kind
      cs.origin = c.origin
      c.actions.each do |a|
        case a.name
        when "record"   then cs.added_transaction_ids << a[0].to_i
        when "declare"  then cs.declared_accounts << a[0]
        when "budget"   then cs.budget_changes << BudgetChange.new(a[0], a[2]?.try(&.to_i64))
        when "unbudget" then cs.budget_changes << BudgetChange.new(a[0], a[1]?.try(&.to_i64))
        when "reverses" then cs.reverses = a[0].to_i
        end
      end
      cs.reverted = c.reverted?
      cs
    end

    # True if a reversing entry already undid changeset `id`.
    def reversed?(id : Int32) : Bool
      @log.commits.any? { |c| c.actions.any? { |a| a.name == "reverses" && a[0].to_i == id } }
    end

    # Undo the most recent ledger change by marking it reverted — as if it
    # never happened, without erasing it from the log. Returns it, or nil if
    # there's nothing to undo.
    def undo_last : Changeset?
      target = @log.commits.reverse_each.find { |c| c.kind == KIND_LEDGER && !c.mark? && !c.reverted? }
      return nil unless target
      @log.lock do
        @log.revert(target.seq, at: now, origin: @origin, kind: KIND_LEDGER, summary: "undo ##{target.seq}: #{target.summary}")
        fold!
      end
      changeset_view(target)
    end

    # Bring back the change `undo` just removed — only while it is the latest
    # thing in the log; any new change invalidates it.
    def redo_last : Changeset?
      last = @log.commits.last?
      return nil unless last && (seq = last.reverts)
      target = @log.commit(seq).not_nil!
      @log.lock do
        @log.unrevert(seq, at: now, origin: @origin, kind: KIND_LEDGER, summary: "redo ##{seq}: #{target.summary}")
        fold!
      end
      changeset_view(target)
    end

    def redo_available? : Bool
      !@log.commits.last?.try(&.reverts).nil?
    end

    # Correct an *older* change the proper accounting way: append a reversing
    # entry. The original is never removed — transactions it added are negated by
    # mirror-image postings, budget changes restored. Returns the reversing
    # changeset, nil if `id` is unknown, or raises if it's already reversed.
    def reverse(id : Int32, at : String, date : String) : Changeset?
      original = changesets.find { |c| c.id == id }
      return nil unless original
      raise Error.new("change ##{id} is already reversed") if reversed?(id)

      seq = nil
      changeset("reverse ##{original.id}: #{original.summary}", at) do
        emit("", Keep::Action.new("reverses", original.id))
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
      end
      changesets.last
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

    # --- migration from a pre-log finfry.json ---------------------------------

    # Turn an older book (state + journal in one JSON file) into a log: each
    # journaled change becomes a commit with the transactions it added; one
    # final `migrated` commit carries everything else. The fold of the new log
    # reproduces the old state. The original file is kept as `.pre-log`.
    private def migrate_to_log! : Nil
      raw = JSON.parse(File.read(@path))
      return if raw["version"]? && raw["state"]? # already a checkpoint (log just missing)
      old = legacy_single_entry?(raw) ? migrate_single_entry(raw) : Database.from_json(raw.to_json)

      File.copy(@path, "#{@path}.pre-log")
      @log = Keep::Log.open(@log.path)
      by_id = {} of Int32 => Transaction
      old.transactions.each { |t| by_id[t.id] = t }
      covered = Set(Int32).new

      old.changesets.each do |cs|
        @log.append(at: cs.at, origin: "migrated", kind: KIND_LEDGER, summary: cs.summary) do |b|
          b.action("reverses", cs.reverses) if cs.reverses
          cs.added_transaction_ids.each do |tid|
            next unless t = by_id[tid]?
            covered << tid
            b.action("record", t.id, t.date, t.description, t.recurrence, Store.flat(t.postings))
          end
          # Declarations aren't replayed per changeset: an account declared
          # then removed would come back. The final commit declares the chart
          # exactly as it stands.
        end
      end

      @log.append(at: now, origin: "migrated", kind: KIND_BOOKKEEPING, summary: "migrated from #{File.basename(@path)}") do |b|
        old.transactions.each do |t|
          next if covered.includes?(t.id)
          b.action("record", t.id, t.date, t.description, t.recurrence, Store.flat(t.postings))
        end
        old.accounts.each { |a| b.action("declare", a) }
        old.budgets.each { |account, limit| b.action("budget", account, limit) }
        old.account_meta.each { |account, meta| meta.each { |k, v| b.action("meta", account, k, v) } }
        b.action("setting", "policy", old.account_policy)
        b.action("setting", "example", "true") if old.example
        old.recurring.each { |r| b.action("rule", r.id, r.description, r.cadence, r.next_date, r.kind, r.active.to_s, Store.flat(r.postings)) }
        old.due_entries.each { |e| b.action("due", e.id, e.rule_id, e.date, e.description, e.cadence, e.status, Store.flat(e.postings)) }
        old.reconciliations.each { |r| b.action("reconcile", r.account, r.statement, r.date, r.statement_date, r.transaction_ids) }
        old.reconciled.each do |account, ids|
          covered_ids = old.reconciliations.select { |r| r.account == account }.flat_map(&.transaction_ids)
          rest = ids - covered_ids
          b.action("reconcile", account, 0, now[0, 10], nil, rest) unless rest.empty?
        end
        old.cleared.each { |account, ids| b.action("clear", account, ids) unless ids.empty? }
      end
    end

    # The oldest format stored each transaction with flat `amount`/`category`/
    # `kind` fields and no `postings`.
    private def legacy_single_entry?(raw : JSON::Any) : Bool
      first = raw["transactions"]?.try(&.as_a?).try(&.first?).try(&.as_h?)
      return false unless first
      first.has_key?("kind") && !first.has_key?("postings")
    end

    private def migrate_single_entry(raw : JSON::Any) : Database
      db = Database.new
      db.accounts = DEFAULT_CHART.dup
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
  end
end
