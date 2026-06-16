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

    it "round-trips with parse" do
      Finfry::Money.format(Finfry::Money.parse("1,000.00")).should eq("$1,000.00")
    end
  end
end

describe Finfry::Store do
  it "adds transactions with incrementing ids and persists them" do
    with_store do |store|
      a = store.add_transaction("2026-06-01", 500_i64, "food", "lunch", "expense")
      b = store.add_transaction("2026-06-02", 1000_i64, "food", "dinner", "expense")
      a.id.should eq(1)
      b.id.should eq(2)

      reloaded = Finfry::Store.new(store.path)
      reloaded.transactions.size.should eq(2)
    end
  end

  it "deletes by id" do
    with_store do |store|
      store.add_transaction("2026-06-01", 500_i64, "food", "lunch", "expense")
      store.delete_transaction(1).try(&.id).should eq(1)
      store.delete_transaction(1).should be_nil
      store.transactions.should be_empty
    end
  end

  it "sums spending per category within a month" do
    with_store do |store|
      store.add_transaction("2026-06-01", 500_i64, "food", "", "expense")
      store.add_transaction("2026-06-20", 700_i64, "food", "", "expense")
      store.add_transaction("2026-07-01", 999_i64, "food", "", "expense")
      store.add_transaction("2026-06-05", 300_i64, "food", "", "income") # ignored

      store.spent("food", "2026-06").should eq(1200_i64)
    end
  end

  it "stores and removes budgets" do
    with_store do |store|
      store.set_budget("food", 40000_i64)
      store.budgets["food"].should eq(40000_i64)
      store.remove_budget("food").should be_true
      store.remove_budget("food").should be_false
    end
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
