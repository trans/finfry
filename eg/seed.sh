#!/usr/bin/env bash
# Build an example book with three months of realistic activity, for
# trying the UI (`just seed` → dev/books.json, which `just dev` serves).
#
#   eg/seed.sh <path-to-book.json> [finfry-binary]
set -euo pipefail
book="${1:?usage: eg/seed.sh <book.json> [finfry]}"
finfry="${2:-./bin/finfry}"
rm -f "$book"
export FINFRY_DATA="$book"
f() { "$finfry" "$@" >/dev/null; }

f accounts add Assets:Checking Assets:Savings Liabilities:CreditCard \
  Income:Salary Income:Interest \
  Expenses:Housing:Rent Expenses:Utilities:Electric Expenses:Utilities:Internet \
  Expenses:Food:Groceries Expenses:Food:Dining Expenses:Food:Coffee \
  Expenses:Transport:Fuel Expenses:Transport:Transit \
  Expenses:Subscriptions Expenses:Health Expenses:Shopping Expenses:Gifts Expenses:Interest
f accounts set Liabilities:CreditCard apr 21.99
f accounts set Liabilities:CreditCard limit 5000
f accounts set Liabilities:CreditCard due-day 18
f accounts set Assets:Savings bank "Ally"

# Opening position, then three months (July–September) of a typical household.
f earn 3200 Income:Salary -m "Opening balance" -d 2026-06-30
f transfer 2500 --from Assets:Checking --to Assets:Savings -m "Opening balance" -d 2026-06-30

month() { # month YYYY-MM
  local m="$1"
  f earn 2750 Income:Salary -m "Paycheck" -d "$m-01" -r monthly
  f earn 2750 Income:Salary -m "Paycheck" -d "$m-15"
  f spend 1450 Expenses:Housing:Rent -m "Rent" -d "$m-02" -r monthly
  f spend 82.40 Expenses:Utilities:Electric -m "Electric" -d "$m-09"
  f spend 69.99 Expenses:Utilities:Internet -m "Internet" -d "$m-11" -r monthly
  f spend 15.49 Expenses:Subscriptions -m "Netflix" -d "$m-05" -r monthly -f Liabilities:CreditCard
  f spend 10.99 Expenses:Subscriptions -m "Spotify" -d "$m-07" -r monthly -f Liabilities:CreditCard
  f spend 124.18 Expenses:Food:Groceries -m "Market run" -d "$m-03" -f Liabilities:CreditCard
  f spend 96.52 Expenses:Food:Groceries -m "Market run" -d "$m-10" -f Liabilities:CreditCard
  f spend 138.07 Expenses:Food:Groceries -m "Market run" -d "$m-17" -f Liabilities:CreditCard
  f spend 88.90 Expenses:Food:Groceries -m "Market run" -d "$m-24" -f Liabilities:CreditCard
  f spend 4.75 Expenses:Food:Coffee -m "Espresso" -d "$m-04" -f Liabilities:CreditCard
  f spend 5.25 Expenses:Food:Coffee -m "Espresso" -d "$m-12" -f Liabilities:CreditCard
  f spend 4.75 Expenses:Food:Coffee -m "Espresso" -d "$m-19" -f Liabilities:CreditCard
  f spend 46.30 Expenses:Food:Dining -m "Dinner out" -d "$m-13" -f Liabilities:CreditCard
  f spend 52.00 Expenses:Transport:Fuel -m "Gas" -d "$m-08"
  f spend 54.10 Expenses:Transport:Fuel -m "Gas" -d "$m-22"
  f spend 40 Expenses:Transport:Transit -m "Transit pass" -d "$m-01"
  f spend 32.00 Expenses:Health -m "Pharmacy" -d "$m-14" -f Liabilities:CreditCard
  f transfer 500 --from Assets:Checking --to Assets:Savings -m "Savings" -d "$m-16" 
}
month 2026-07
f spend 89.99 Expenses:Shopping -m "Running shoes" -d 2026-07-20 -f Liabilities:CreditCard
f transfer 600 --from Assets:Checking --to Liabilities:CreditCard -m "Card payment" -d 2026-07-18
month 2026-08
f spend 45 Expenses:Gifts -m "Birthday gift" -d 2026-08-21 -f Liabilities:CreditCard
f transfer 620 --from Assets:Checking --to Liabilities:CreditCard -m "Card payment" -d 2026-08-18
f earn 6.12 Income:Interest -m "Interest" -d 2026-08-31 --to Assets:Savings
month 2026-09
f transfer 580 --from Assets:Checking --to Liabilities:CreditCard -m "Card payment" -d 2026-09-18

f budget set Expenses:Food 450
f budget set Expenses:Food:Dining 80
f budget set Expenses:Transport 150
f budget set Expenses:Shopping 100

f recurring add 1450 Expenses:Housing:Rent -m Rent -e monthly --start 2026-10-02
f recurring add 69.99 Expenses:Utilities:Internet -m Internet -e monthly --start 2026-10-11
f recurring add 15.49 Expenses:Subscriptions -m Netflix -e monthly --start 2026-10-05 -c Liabilities:CreditCard
f recurring add 29.99 Expenses:Health -m "Gym" -e monthly --start 2026-09-15 -c Liabilities:CreditCard
f recurring interest Liabilities:CreditCard --every monthly --start 2026-09-18

# July's checking statement, reconciled; August is in progress.
july_ids=$("$finfry" register -a Assets:Checking -m 2026-07 | awk '{print substr($1,2)}' | tr '\n' ' ')
f reconcile Assets:Checking clear $july_ids
bal=$("$finfry" reconcile Assets:Checking | awk '/cleared balance/ {print $3}')
f reconcile Assets:Checking commit "$bal" --as-of 2026-07-31
aug_ids=$("$finfry" register -a Assets:Checking -m 2026-08 | awk '{print substr($1,2)}' | head -6 | tr '\n' ' ')
f reconcile Assets:Checking clear $aug_ids

echo "seeded $book"
