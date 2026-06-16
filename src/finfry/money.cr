module Finfry
  # Money is stored everywhere as a whole number of cents (`Int64`) so we never
  # accumulate floating-point rounding error. This module is the only place that
  # converts to and from the human-facing decimal string.
  module Money
    class Error < Exception; end

    # Parse a user-supplied amount like "12.50", "$1,234.5", "12" or "-3.99"
    # into cents. Raises `Money::Error` on anything it can't make sense of.
    def self.parse(input : String) : Int64
      cleaned = input.strip.gsub(",", "").lchop("$")
      negative = cleaned.starts_with?('-')
      cleaned = cleaned.lchop("-").lchop("$") if negative

      unless cleaned =~ /\A(\d+)(?:\.(\d{1,2}))?\z/
        raise Error.new("invalid amount: #{input.inspect} (expected something like 12.50)")
      end

      dollars = $1.to_i64
      cents_part = $2?
      cents = case cents_part
              when Nil then 0_i64
              else          cents_part.ljust(2, '0').to_i64
              end

      total = dollars * 100 + cents
      negative ? -total : total
    end

    # Format cents as a "$1,234.56" string.
    def self.format(cents : Int64) : String
      sign = cents < 0 ? "-" : ""
      value = cents.abs
      whole = (value // 100).to_s
      frac = (value % 100).to_s.rjust(2, '0')

      # Insert thousands separators into the whole part.
      grouped = whole.reverse.gsub(/(\d{3})(?=\d)/, "\\1,").reverse
      "#{sign}$#{grouped}.#{frac}"
    end
  end
end
