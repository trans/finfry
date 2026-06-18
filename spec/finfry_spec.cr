require "./spec_helper"

describe Finfry::Money do
  describe ".parse" do
    it "parses whole dollars" do
      Finfry::Money.parse("12").should eq(1200_i64)
    end

    it "parses dollars and cents" do
      Finfry::Money.parse("12.50").should eq(1250_i64)
    end

    it "pads a single decimal digit" do
      Finfry::Money.parse("12.5").should eq(1250_i64)
    end

    it "strips currency symbols and separators" do
      Finfry::Money.parse("$1,234.56").should eq(123456_i64)
    end

    it "parses negative amounts" do
      Finfry::Money.parse("-3.99").should eq(-399_i64)
    end

    it "raises on garbage" do
      expect_raises(Finfry::Money::Error) { Finfry::Money.parse("notmoney") }
    end

    it "raises on too many decimals" do
      expect_raises(Finfry::Money::Error) { Finfry::Money.parse("1.234") }
    end
  end

  describe ".format" do
    it "formats cents as currency" do
      Finfry::Money.format(1250_i64).should eq("$12.50")
    end

    it "inserts thousands separators" do
      Finfry::Money.format(123456_i64).should eq("$1,234.56")
    end

    it "formats negatives" do
      Finfry::Money.format(-399_i64).should eq("-$3.99")
    end
  end
end

describe Finfry::Transaction do
  it "is balanced when postings sum to zero" do
    txn = Finfry::Transaction.new(1, "2026-06-01", "x", [
      Finfry::Posting.new("Expenses:Food", 500_i64),
      Finfry::Posting.new("Assets:Checking", -500_i64),
    ])
    txn.balanced?.should be_true
  end

  it "is unbalanced otherwise" do
    txn = Finfry::Transaction.new(1, "2026-06-01", "x", [
      Finfry::Posting.new("Expenses:Food", 500_i64),
      Finfry::Posting.new("Assets:Checking", -400_i64),
    ])
    txn.balanced?.should be_false
    txn.imbalance.should eq(100_i64)
  end

  it "respects the colon boundary when matching subtrees" do
    txn = Finfry::Transaction.new(1, "2026-06-01", "x", [
      Finfry::Posting.new("Expenses:Food:Coffee", 500_i64),
      Finfry::Posting.new("Assets:Checking", -500_i64),
    ])
    txn.touches?("Expenses:Food").should be_true # parent matches descendant
    txn.touches?("Expenses:Foo").should be_false # not a colon-boundary prefix
  end
end

describe Finfry::Store do
  it "records balanced transactions with incrementing ids and persists them" do
    with_store do |store|
      a = store.record("2026-06-01", "lunch", expense("Expenses:Food", 500))
      b = store.record("2026-06-02", "dinner", expense("Expenses:Food", 1000))
      a.id.should eq(1)
      b.id.should eq(2)

      Finfry::Store.new(store.path).transactions.size.should eq(2)
    end
  end

  it "rejects unbalanced transactions" do
    with_store do |store|
      expect_raises(Finfry::Error, /balance/) do
        store.record("2026-06-01", "bad", [
          Finfry::Posting.new("Expenses:Food", 500_i64),
          Finfry::Posting.new("Assets:Checking", -400_i64),
        ])
      end
    end
  end

  it "computes balances with subtree rollup and sign" do
    with_store do |store|
      store.record("2026-06-01", "", expense("Expenses:Food:Coffee", 500))
      store.record("2026-06-02", "", expense("Expenses:Food:Snacks", 300))

      all = store.balances
      all["Expenses:Food:Coffee"].should eq(500_i64)
      all["Assets:Checking"].should eq(-800_i64)

      store.balances("Expenses:Food").values.sum.should eq(800_i64)
    end
  end

  it "sums spending into an account subtree within a month" do
    with_store do |store|
      store.record("2026-06-01", "", expense("Expenses:Food:Coffee", 500))
      store.record("2026-06-20", "", expense("Expenses:Food:Snacks", 700))
      store.record("2026-07-01", "", expense("Expenses:Food:Coffee", 999))

      store.spent("Expenses:Food", "2026-06").should eq(1200_i64)
    end
  end

  it "lists distinct used accounts" do
    with_store do |store|
      store.record("2026-06-01", "", expense("Expenses:Food", 500))
      store.used_accounts.should eq(["Assets:Checking", "Expenses:Food"])
    end
  end

  it "treats declared and used accounts as known" do
    with_store do |store|
      store.declare_account("Expenses:Travel")
      store.record("2026-06-01", "", expense("Expenses:Food", 500))
      store.account_known?("Expenses:Travel").should be_true # declared
      store.account_known?("Expenses:Food").should be_true   # used
      store.account_known?("Expenses:Nope").should be_false
    end
  end

  it "renames an account across postings and budgets" do
    with_store do |store|
      store.record("2026-06-01", "", expense("Expenses:Foood", 500))
      store.set_budget("Expenses:Foood", 10000_i64)
      count = store.rename_account("Expenses:Foood", "Expenses:Food")
      count.should eq(1)
      store.used_accounts.includes?("Expenses:Food").should be_true
      store.used_accounts.includes?("Expenses:Foood").should be_false
      store.budgets["Expenses:Food"].should eq(10000_i64)
    end
  end

  it "defaults to the strict policy and seeds a starter chart on a new ledger" do
    with_store do |store|
      store.account_policy.should eq("strict")
      store.declared_accounts.should contain("Assets:Checking")
      store.set_account_policy("off")
      Finfry::Store.new(store.path).account_policy.should eq("off")
    end
  end

  it "undoes the last change by removing it outright" do
    with_store do |store|
      store.changeset("a", "t1") { store.record("2026-06-01", "a", expense("Expenses:Food", 100)) }
      store.changeset("b", "t2") { store.record("2026-06-02", "b", expense("Expenses:Food", 200)) }

      store.undo_last.not_nil!.summary.should eq("b") # pops the newest
      store.transactions.size.should eq(1)            # b removed, not reversed
      store.undo_last.not_nil!.summary.should eq("a")
      store.transactions.should be_empty
      store.undo_last.should be_nil # nothing left
    end
  end

  it "restores a budget when the last change is popped" do
    with_store do |store|
      store.changeset("budget", "t1") { store.set_budget("Expenses:Food", 40000_i64) }
      store.undo_last
      store.budgets.has_key?("Expenses:Food").should be_false
    end
  end

  it "redoes the change most recently popped, until new activity invalidates it" do
    with_store do |store|
      store.changeset("a", "t1") { store.record("2026-06-01", "a", expense("Expenses:Food", 100)) }
      store.undo_last
      store.transactions.should be_empty

      store.redo_last.not_nil!.summary.should eq("a")
      store.transactions.size.should eq(1)
      store.redo_last.should be_nil # consumed

      store.undo_last
      store.changeset("b", "t2") { store.record("2026-06-02", "b", expense("Expenses:Food", 200)) }
      store.redo_last.should be_nil # new activity invalidated the redo
    end
  end

  it "reverses an older change by appending a mirror-image entry" do
    with_store do |store|
      store.changeset("rent", "t1") { store.record("2026-06-01", "rent", expense("Expenses:Housing", 120000)) }
      store.changeset("food", "t2") { store.record("2026-06-02", "food", expense("Expenses:Food", 500)) }

      store.reverse(1, "t3", "2026-06-17").not_nil!.reverses.should eq(1)
      store.transactions.size.should eq(3)                       # original kept + reversal added
      store.balances("Expenses:Housing").values.sum.should eq(0) # netted out
      store.balances("Expenses:Food").values.sum.should eq(500)  # untouched
      store.reversed?(1).should be_true
      expect_raises(Finfry::Error, /already reversed/) { store.reverse(1, "t4", "2026-06-17") }
    end
  end

  it "resolves the ledger path from FINFRY_DATA, then XDG, then the default" do
    with_env("FINFRY_DATA", "/tmp/explicit.json") do
      Finfry::Store.default_path.should eq("/tmp/explicit.json")
    end
    with_env("FINFRY_DATA", nil) do
      with_env("XDG_DATA_HOME", "/tmp/xdg") do
        Finfry::Store.default_path.should eq(File.join("/tmp/xdg", "finfry", "data.json"))
      end
    end
  end

  it "stores and removes budgets" do
    with_store do |store|
      store.set_budget("Expenses:Food", 40000_i64)
      store.budgets["Expenses:Food"].should eq(40000_i64)
      store.remove_budget("Expenses:Food").should be_true
      store.remove_budget("Expenses:Food").should be_false
    end
  end

  it "migrates a legacy single-entry ledger and backs it up" do
    path = File.tempname("finfry_legacy", ".json")
    File.write(path, {
      "next_id"      => 3,
      "transactions" => [
        {"id" => 1, "date" => "2026-05-01", "amount" => 1250, "category" => "food", "description" => "coffee", "kind" => "expense"},
        {"id" => 2, "date" => "2026-05-01", "amount" => 300000, "category" => "salary", "description" => "pay", "kind" => "income"},
      ],
      "budgets" => {"food" => 40000},
    }.to_json)

    begin
      store = Finfry::Store.new(path)
      File.exists?("#{path}.bak").should be_true # original preserved
      store.db.next_id.should eq(3)

      balances = store.balances
      balances["Expenses:food"].should eq(1250_i64)
      balances["Income:salary"].should eq(-300000_i64)
      balances["Assets:Checking"].should eq(298750_i64)
      store.budgets["Expenses:food"].should eq(40000_i64)

      store.transactions.all?(&.balanced?).should be_true
    ensure
      File.delete(path) if File.exists?(path)
      File.delete("#{path}.bak") if File.exists?("#{path}.bak")
    end
  end
end

describe Finfry::Recurrence do
  it "knows period lengths in days" do
    Finfry::Recurrence.days("weekly").should eq(7.0)
    Finfry::Recurrence.days("yearly").should eq(365.25)
  end

  it "amortizes an amount to a per-day cost" do
    # $15.49/month over 365.25/12 days ≈ 50.9 cents/day
    Finfry::Recurrence.per_day(1549_i64, "monthly").should be_close(50.89, 0.1)
  end

  it "rejects unknown cadences" do
    Finfry::Recurrence.valid?("fortnightly").should be_false
    expect_raises(Finfry::Error) { Finfry::Recurrence.days("fortnightly") }
  end
end

describe "Finfry.recurring_items" do
  it "keeps only the most recent occurrence of each stream" do
    txns = [
      recurring_expense(1, "2026-05-01", "Netflix", "Expenses:Subs:Netflix", 1549, "monthly"),
      recurring_expense(2, "2026-06-01", "Netflix", "Expenses:Subs:Netflix", 1549, "monthly"),
      recurring_expense(3, "2026-06-01", "Gym", "Expenses:Health:Gym", 4000, "monthly"),
    ]
    items = Finfry.recurring_items(txns)
    items.map(&.label).sort.should eq(["Gym", "Netflix"]) # Netflix not double-counted
  end

  it "excludes one-off transactions" do
    txns = [
      recurring_expense(1, "2026-06-01", "Netflix", "Expenses:Subs:Netflix", 1549, "monthly"),
      Finfry::Transaction.new(2, "2026-06-02", "latte", expense("Expenses:Food:Coffee", 500)),
    ]
    Finfry.recurring_items(txns).map(&.label).should eq(["Netflix"])
  end

  it "classifies income vs expense and sorts by per-day cost" do
    txns = [
      recurring_expense(1, "2026-06-01", "Rent", "Expenses:Housing:Rent", 120000, "monthly"),
      recurring_expense(2, "2026-06-01", "Netflix", "Expenses:Subs:Netflix", 1549, "monthly"),
      Finfry::Transaction.new(3, "2026-06-01", "Salary", [
        Finfry::Posting.new("Assets:Checking", 400000_i64),
        Finfry::Posting.new("Income:Salary", -400000_i64),
      ], "monthly"),
    ]
    items = Finfry.recurring_items(txns)
    items.first.label.should eq("Salary") # largest per-day first
    items.find { |i| i.label == "Salary" }.not_nil!.income?.should be_true
    items.find { |i| i.label == "Rent" }.not_nil!.expense?.should be_true
  end
end

describe Finfry::Store do
  it "persists recurrence on a transaction" do
    with_store do |store|
      store.record("2026-06-01", "Netflix", expense("Expenses:Subs:Netflix", 1549), "monthly")
      Finfry::Store.new(store.path).transactions.first.recurrence.should eq("monthly")
    end
  end
end

describe "Finfry.postings_for" do
  it "builds a balanced expense pair" do
    p = Finfry.postings_for("expense", 500_i64, "Expenses:Food", "Assets:Checking")
    p.map(&.account).should eq(["Expenses:Food", "Assets:Checking"])
    p.map(&.amount).should eq([500_i64, -500_i64])
  end

  it "flips direction for income" do
    p = Finfry.postings_for("income", 500_i64, "Income:Salary", "Assets:Checking")
    p.map(&.account).should eq(["Assets:Checking", "Income:Salary"])
    p.map(&.amount).should eq([500_i64, -500_i64])
  end

  it "moves value for a transfer (account is destination)" do
    p = Finfry.postings_for("transfer", 500_i64, "Assets:Savings", "Assets:Checking")
    p.map(&.amount).sum.should eq(0_i64)
    p[0].account.should eq("Assets:Savings")
    p[0].amount.should eq(500_i64)
  end

  it "raises on an unknown kind" do
    expect_raises(Finfry::Error) { Finfry.postings_for("bogus", 1_i64, "a", "b") }
  end
end

describe Finfry::AI do
  describe "#build_body" do
    it "produces a valid request with model, schema, and accounts in the prompt" do
      ai = Finfry::AI.new("test-key", "claude-opus-4-8")
      body = JSON.parse(ai.build_body("spent $5 on coffee",
        accounts: ["Expenses:Food:Coffee", "Assets:Checking"],
        today: "2026-06-17",
        default_asset: "Assets:Checking"))

      body["model"].should eq("claude-opus-4-8")
      body["messages"][0]["content"].should eq("spent $5 on coffee")
      body["system"].as_s.should contain("Expenses:Food:Coffee")
      body["system"].as_s.should contain("2026-06-17")
      props = body["output_config"]["format"]["schema"]["properties"]
      props["kind"]?.should_not be_nil
      props["counter_account"]?.should_not be_nil
    end
  end

  describe ".intent_from_response" do
    it "extracts the intent from the first text block" do
      response = {
        "stop_reason" => "end_turn",
        "content"     => [
          {"type" => "text", "text" => {
            "kind"            => "expense",
            "amount"          => "50.00",
            "account"         => "Expenses:Food:Coffee",
            "counter_account" => "Liabilities:CreditCards:ChasePlatinum",
            "date"            => "2026-06-15",
            "description"     => "Starbucks",
            "recurrence"      => "none",
          }.to_json},
        ],
      }.to_json

      intent = Finfry::AI.intent_from_response(response)
      intent.kind.should eq("expense")
      intent.amount.should eq("50.00")
      intent.counter_account.should eq("Liabilities:CreditCards:ChasePlatinum")
      intent.recurrence_or_nil.should be_nil
    end

    it "maps recurrence to nil only for \"none\"" do
      base = {"kind" => "expense", "amount" => "1", "account" => "a", "counter_account" => "b",
              "date" => "2026-06-17", "description" => "x"}
      monthly = {"content" => [{"type" => "text", "text" => base.merge({"recurrence" => "monthly"}).to_json}]}.to_json
      Finfry::AI.intent_from_response(monthly).recurrence_or_nil.should eq("monthly")
    end

    it "raises a friendly error when there is no content" do
      expect_raises(Finfry::Error, /no usable content/) do
        Finfry::AI.intent_from_response({"content" => [] of String}.to_json)
      end
    end
  end
end

# A balanced, recurring expense transaction paid from Assets:Checking.
def recurring_expense(id : Int32, date : String, desc : String, account : String,
                      cents : Int32, recurrence : String) : Finfry::Transaction
  Finfry::Transaction.new(id, date, desc, expense(account, cents), recurrence)
end

# A balanced expense posting pair paid from Assets:Checking.
def expense(account : String, cents : Int32) : Array(Finfry::Posting)
  [
    Finfry::Posting.new(account, cents.to_i64),
    Finfry::Posting.new("Assets:Checking", -cents.to_i64),
  ]
end

# Temporarily set (or clear, with nil) an env var for the duration of the block.
def with_env(key : String, value : String?, &)
  previous = ENV[key]?
  value ? (ENV[key] = value) : ENV.delete(key)
  begin
    yield
  ensure
    previous ? (ENV[key] = previous) : ENV.delete(key)
  end
end

# Runs the block with a Store backed by a throwaway temp file.
def with_store(&)
  path = File.tempname("finfry_spec", ".json")
  begin
    yield Finfry::Store.new(path)
  ensure
    File.delete(path) if File.exists?(path)
  end
end
