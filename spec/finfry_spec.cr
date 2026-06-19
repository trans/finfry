require "./spec_helper"
require "file_utils"

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

  it "uses FINFRY_DATA when set, above everything else" do
    with_env("FINFRY_DATA", "/tmp/explicit.json") do
      Finfry::Store.default_path.should eq("/tmp/explicit.json")
    end
  end

  it "discovers the nearest book walking up, else falls back to the global path" do
    root = File.tempname("finfry_book")
    Dir.mkdir_p(File.join(root, "sub"))
    File.write(File.join(root, Finfry::Store::BOOK_FILE), "{}")
    empty = File.tempname("finfry_empty")
    Dir.mkdir_p(empty)

    begin
      with_env("FINFRY_DATA", nil) do
        with_env("XDG_DATA_HOME", "/tmp/xdg") do
          Dir.cd(File.join(root, "sub")) do
            Finfry::Store.default_path.should eq(File.join(root, Finfry::Store::BOOK_FILE))
          end
          Dir.cd(empty) do
            Finfry::Store.default_path.should eq(File.join("/tmp/xdg", "finfry", "data.json"))
          end
        end
      end
    ensure
      FileUtils.rm_rf(root)
      FileUtils.rm_rf(empty)
    end
  end

  it "sets, reads, and removes account metadata" do
    with_store do |store|
      store.set_account_meta("Liabilities:CreditCards:Chase", "apr", "19.99")
      store.set_account_meta("Liabilities:CreditCards:Chase", "limit", "5000")
      store.account_meta("Liabilities:CreditCards:Chase").should eq({"apr" => "19.99", "limit" => "5000"})

      store.unset_account_meta("Liabilities:CreditCards:Chase", "limit").should be_true
      store.account_meta("Liabilities:CreditCards:Chase").should eq({"apr" => "19.99"})
      store.unset_account_meta("Liabilities:CreditCards:Chase", "limit").should be_false
      store.account_meta("Nope").should be_empty
    end
  end

  it "carries metadata across a rename" do
    with_store do |store|
      store.set_account_meta("Liabilities:CreditCards:Chase", "apr", "19.99")
      store.rename_account("Liabilities:CreditCards:Chase", "Liabilities:CreditCards:Sapphire")
      store.account_meta("Liabilities:CreditCards:Sapphire").should eq({"apr" => "19.99"})
      store.account_meta("Liabilities:CreditCards:Chase").should be_empty
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

  describe ".advance" do
    it "steps by cadence" do
      Finfry::Recurrence.advance("2026-06-19", "weekly").should eq("2026-06-26")
      Finfry::Recurrence.advance("2026-06-19", "monthly").should eq("2026-07-19")
      Finfry::Recurrence.advance("2026-06-19", "yearly").should eq("2027-06-19")
    end

    it "clamps month-end overflow" do
      Finfry::Recurrence.advance("2026-01-31", "monthly").should eq("2026-02-28")
    end
  end

  describe ".occurrences" do
    it "lists occurrences up to and including the cutoff (catch-up)" do
      Finfry::Recurrence.occurrences("2026-04-01", "monthly", "2026-06-19")
        .should eq(["2026-04-01", "2026-05-01", "2026-06-01"])
    end

    it "is empty when the first occurrence is in the future" do
      Finfry::Recurrence.occurrences("2026-07-01", "monthly", "2026-06-19").should be_empty
    end
  end
end

describe Finfry::Store do
  it "adds and turns off recurring rules" do
    with_store do |store|
      rule = store.add_recurring_rule("Netflix", "monthly", "2026-06-01", expense("Expenses:Subs:Netflix", 1549))
      rule.id.should eq(1)
      store.add_recurring_rule("Rent", "monthly", "2026-06-01", expense("Expenses:Housing", 120000)).id.should eq(2)
      store.recurring_rules.size.should eq(2)

      store.deactivate_rule(1).should be_true
      store.recurring_rules.find { |r| r.id == 1 }.not_nil!.active.should be_false
      store.deactivate_rule(99).should be_false

      Finfry::Store.new(store.path).recurring_rules.size.should eq(2) # persisted
    end
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

describe "Finfry.balance_sheet" do
  it "sections accounts and balances an opening-balance ledger" do
    balances = {"Assets:Checking:TD" => 3902_i64, "Equity:OpeningBalances" => -3902_i64}
    bs = Finfry.balance_sheet(balances)
    bs.total_assets.should eq(3902)
    bs.total_equity.should eq(3902) # opening equity, no net income yet
    bs.net_income.should eq(0)
    bs.balanced?.should be_true
  end

  it "folds net income (income − expenses) into equity" do
    balances = {"Assets:Checking" => 7000_i64, "Income:Salary" => -10000_i64, "Expenses:Food" => 3000_i64}
    bs = Finfry.balance_sheet(balances)
    bs.net_income.should eq(7000) # 100 earned − 30 spent
    bs.total_assets.should eq(7000)
    bs.total_equity.should eq(7000) # net income only
    bs.balanced?.should be_true
  end

  it "flips liabilities to read positive (credit-card purchase)" do
    balances = {"Expenses:Food" => 5000_i64, "Liabilities:CreditCard" => -5000_i64}
    bs = Finfry.balance_sheet(balances)
    bs.total_liabilities.should eq(5000) # owed, shown positive
    bs.net_income.should eq(-5000)       # spent 50, earned nothing
    bs.total_assets.should eq(0)
    bs.balanced?.should be_true # 0 = 50 + (-50)
  end

  it "flags an imbalance for tampered data" do
    Finfry.balance_sheet({"Assets:Checking" => 100_i64}).balanced?.should be_false
  end
end

describe Finfry::AI do
  describe ".parse_turn" do
    it "collects text and tool calls, not done while a tool is requested" do
      resp = JSON.parse(%({
        "stop_reason": "tool_use",
        "content": [
          {"type": "text", "text": "Let me check."},
          {"type": "tool_use", "id": "tu_1", "name": "balance", "input": {"prefix": "Expenses"}}
        ]
      }))
      turn = Finfry::AI.parse_turn(resp)
      turn.text.should eq("Let me check.")
      turn.done?.should be_false
      turn.tool_calls.size.should eq(1)
      turn.tool_calls.first.name.should eq("balance")
      turn.tool_calls.first.input["prefix"].should eq("Expenses")
    end

    it "is done on end_turn" do
      resp = JSON.parse(%({"stop_reason": "end_turn", "content": [{"type": "text", "text": "All set."}]}))
      turn = Finfry::AI.parse_turn(resp)
      turn.done?.should be_true
      turn.text.should eq("All set.")
    end
  end

  describe "#build_request" do
    it "includes the model, system, tools, and messages" do
      ai = Finfry::AI.new("test-key", "claude-opus-4-8")
      tools = [Finfry::AI::ToolDef.new("balance", "show balances", JSON.parse(%({"type": "object", "properties": {}})))]
      body = JSON.parse(ai.build_request("you are finfry", tools, [%({"role":"user","content":"hi"})]))
      body["model"].should eq("claude-opus-4-8")
      body["system"].should eq("you are finfry")
      body["tools"][0]["name"].should eq("balance")
      body["messages"][0]["content"].should eq("hi")
    end
  end
end

describe Finfry::MCP do
  it "serves initialize, tools/list, and an executing tools/call" do
    path = File.tempname("finfry_mcp", ".json")
    begin
      requests = [
        %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}),
        %({"jsonrpc":"2.0","method":"notifications/initialized"}),
        %({"jsonrpc":"2.0","id":2,"method":"tools/list"}),
        %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"spend","arguments":{"amount":"4.50","account":"Expenses:Food","date":"2026-06-18"}}}),
      ]
      output = IO::Memory.new
      Finfry::MCP.new(Finfry::Store.new(path), IO::Memory.new(requests.join("\n") + "\n"), output).run

      replies = output.to_s.each_line.reject(&.blank?).map { |l| JSON.parse(l) }.to_a
      replies.size.should eq(3) # the notification gets no reply

      replies[0]["result"]["serverInfo"]["name"].should eq("finfry")
      replies[0]["result"]["protocolVersion"].should eq("2025-06-18")
      replies[1]["result"]["tools"].as_a.map(&.["name"].as_s).should contain("spend")
      replies[2]["result"]["isError"].should eq(false)
      replies[2]["result"]["content"][0]["text"].as_s.should contain("Recorded")

      Finfry::Store.new(path).transactions.size.should eq(1) # the write persisted
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "reports a tool error without crashing the server" do
    path = File.tempname("finfry_mcp", ".json")
    begin
      request = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"spend","arguments":{"amount":"5","account":"Expenses:Nope"}}})
      output = IO::Memory.new
      Finfry::MCP.new(Finfry::Store.new(path), IO::Memory.new(request + "\n"), output).run

      reply = JSON.parse(output.to_s.each_line.reject(&.blank?).to_a.first)
      reply["result"]["isError"].should eq(true)
      reply["result"]["content"][0]["text"].as_s.should contain("unknown account")
    ensure
      File.delete(path) if File.exists?(path)
    end
  end
end

describe "Finfry::App.merge_mcp_config" do
  it "adds a finfry server pinned to the book when there's no config" do
    cfg = JSON.parse(Finfry::App.merge_mcp_config(nil, "/books/p/finfry.json"))
    cfg["mcpServers"]["finfry"]["command"].should eq("finfry")
    cfg["mcpServers"]["finfry"]["args"].should eq(["mcp"])
    cfg["mcpServers"]["finfry"]["env"]["FINFRY_DATA"].should eq("/books/p/finfry.json")
  end

  it "preserves other servers when merging" do
    existing = %({"mcpServers":{"other":{"command":"x","args":[]}}})
    cfg = JSON.parse(Finfry::App.merge_mcp_config(existing, "/b/finfry.json"))
    cfg["mcpServers"]["other"]["command"].should eq("x")
    cfg["mcpServers"]["finfry"]?.should_not be_nil
  end
end

describe Finfry::App do
  it "exposes finfry commands as agent tools" do
    path = File.tempname("finfry_app", ".json")
    begin
      tools = Finfry::App.new(Finfry::Store.new(path)).agent_tools
      names = tools.map(&.name)
      names.should contain("spend")
      names.should contain("balance")
      spend = tools.find { |t| t.name == "spend" }.not_nil!
      spend.input_schema["required"].as_a.map(&.as_s).should contain("amount")
    ensure
      File.delete(path) if File.exists?(path)
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
