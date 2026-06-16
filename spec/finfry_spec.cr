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

  it "lists distinct accounts" do
    with_store do |store|
      store.record("2026-06-01", "", expense("Expenses:Food", 500))
      store.accounts.should eq(["Assets:Checking", "Expenses:Food"])
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

# A balanced expense posting pair paid from Assets:Checking.
def expense(account : String, cents : Int32) : Array(Finfry::Posting)
  [
    Finfry::Posting.new(account, cents.to_i64),
    Finfry::Posting.new("Assets:Checking", -cents.to_i64),
  ]
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
