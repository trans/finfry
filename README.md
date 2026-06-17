# finfry

A command-line budget & expense tracker written in [Crystal](https://crystal-lang.org),
built on the [Jargon](https://github.com/trans/jargon) CLI shard. It keeps a
proper **double-entry ledger** stored as plain JSON — every transaction moves
money between accounts and always balances to zero.

## Installation

```sh
shards install
shards build --release
```

The `finfry` binary is produced in `./bin`.

## Concepts

Accounts are hierarchical, colon-separated names. By convention:

- `Assets:*` — what you own (`Assets:Checking`, `Assets:Savings`)
- `Liabilities:*` — what you owe (`Liabilities:CreditCards:ChasePlatinum`)
- `Income:*` — where money comes from (`Income:Salary`)
- `Expenses:*` — where it goes (`Expenses:Food:Coffee`)

Every transaction is a set of **postings** (an account + a signed amount) that
sum to zero. You rarely write that by hand — the `spend`/`earn`/`transfer`
commands build the balanced pair for you.

### Chart of accounts

An account is **known** if it's been declared in the chart or already used by a
posting. A new ledger is seeded with a small starter chart (`Assets:Checking`,
`Expenses:Food`, …). How finfry reacts to an *unknown* account is set per ledger:

- **`strict`** (default) — recording to an unknown account is rejected; declare
  it first with `finfry accounts add`. The error suggests close matches, so a
  typo (`Expenses:Foood`) is caught instead of silently becoming a new account.
- **`guard`** — prompts ("`Expenses:Foood` — did you mean `Expenses:Food`?
  Create it? [y/N]") and declares it on confirmation.
- **`off`** — any referenced account is created silently.

```sh
finfry accounts                         # list known accounts (declared + used)
finfry accounts add Expenses:Food:Coffee Assets:Brokerage
finfry accounts rename Expenses:Foood Expenses:Food   # rewrites postings; merges if target exists
finfry accounts rm Assets:Brokerage     # remove from the chart
finfry accounts policy guard            # strict | guard | off (no arg prints current)
```

The AI path respects the policy too: a proposal that introduces a new account
shows it as `New account: …`, and your confirmation is the deliberate "yes" that
declares it — even in strict mode.

### Sign convention

Amounts are signed cents internally. `Assets`/`Expenses` are debit-normal
(positive), `Income`/`Liabilities`/`Equity` are credit-normal. Reports flip the
sign on credit-normal accounts so they read as positive numbers.

## Usage

### AI-assisted entry

The quickest way to record something is to just describe it. `finfry ai` sends
your description to Claude, maps it to balanced double-entry postings against
your existing accounts, shows the proposal, and records it once you confirm:

```sh
export ANTHROPIC_API_KEY=sk-ant-...

finfry ai "spent $50 at Starbucks yesterday on my Chase Platinum CC"
# Proposed: 2026-06-15  Starbucks
#     Expenses:Food:Coffee                      $50.00
#     Liabilities:CreditCards:ChasePlatinum    -$50.00
# Record this? [y/N]

echo "netflix 15.49 monthly" | finfry ai --yes   # pipe + skip the prompt
```

It reuses the accounts you already have so naming stays consistent, and resolves
relative dates like "yesterday". The AI only classifies and maps accounts —
finfry assembles the balanced postings itself, so the books can't be thrown off.
Set `FINFRY_MODEL` to override the model (default `claude-opus-4-8`).

### Manual entry

```sh
# Spend (default funding account is Assets:Checking)
finfry spend 50 Expenses:Food:Coffee -m "Starbucks" -d 2026-06-15

# Spend on a credit card (any account works as the source)
finfry spend 89.99 Expenses:Shopping -f Liabilities:CreditCards:ChasePlatinum

# Income
finfry earn 3000 Income:Salary

# Tag recurring items with a cadence (daily/weekly/biweekly/monthly/quarterly/yearly)
finfry spend 15.49 Expenses:Subscriptions:Netflix -m Netflix -r monthly
finfry earn 4000 Income:Salary -m Salary -r monthly

# Move money between accounts
finfry transfer 500 --from Assets:Checking --to Assets:Savings

# Split one purchase across several accounts. A trailing lone account is
# inferred so the transaction balances:
finfry add -m "market run" \
  Expenses:Food:Groceries 42.00 \
  Expenses:Food:Snacks    8.00 \
  Assets:Checking            # amount inferred: -50.00

# Reports
finfry list [-a Expenses:Food] [-m 2026-06] [-n 10]   # transactions
finfry balance [Assets]                                # account balances
finfry report [-m 2026-06]                             # income statement
finfry daily                                           # per-day cost of recurring items
finfry accounts                                        # accounts in use
finfry path                                            # print the active ledger file

# Budgets (per account, rolled up over the subtree)
finfry budget set Expenses:Food 400
finfry budget list
finfry budget rm Expenses:Food

# Delete a transaction by id (shown in `list`)
finfry delete 3
```

Run `finfry --help`, or `finfry <command> --help`, for full options.

### Recurring items & daily cost

Tag a transaction with `-r <cadence>` to mark it recurring. `finfry daily` then
shows what each commitment costs **per day**, derived from its cadence (e.g. a
$15.49/month subscription is `15.49 ÷ (365.25/12) ≈ $0.51/day`), plus a total
burn rate projected to monthly and yearly equivalents:

```
Recurring expenses
  Rent     monthly   $1,200.00  →   $39.43/day
  Netflix  monthly      $15.49  →    $0.51/day
  Prime    yearly      $119.88  →    $0.33/day
  Total                            $41.58/day  ($1,265.48/mo, $15,185.76/yr)
```

A recurring stream is identified by its description (or, if blank, the accounts
it touches), and only its most recent occurrence counts — so recording the same
monthly bill repeatedly doesn't inflate the daily figure.

### Amounts

Amounts accept a `$` and thousands separators (`$1,234.56`) and are stored as
integer cents, so there is no floating-point rounding error.

### Data storage

The ledger is a single JSON file, by default at:

```
$XDG_DATA_HOME/finfry/data.json   # typically ~/.local/share/finfry/data.json
```

Set `FINFRY_DATA` to use a different file. Writes are atomic (temp file +
rename), and an older single-entry ledger is migrated to double-entry on first
load (the original is kept as a `.bak`).

## Development

```sh
crystal spec          # run the test suite
shards build          # build a debug binary
crystal tool format   # format the source
```

Layout:

- `src/finfry/money.cr` — parse/format money as integer cents
- `src/finfry/models.cr` — `Posting`, `Transaction`, `Database` records
- `src/finfry/recurrence.cr` — cadence→per-day amortization and recurring-item rollup
- `src/finfry/store.cr` — JSON persistence, queries, legacy migration
- `src/finfry/ai.cr` — the `Finfry::AI` seam: natural-language → structured intent
  via the Claude API (raw HTTP, no SDK); swappable behind one module
- `src/finfry/app.cr` — Jargon CLI definition and command handlers; the shared
  `commit`/`render`/`postings_for` core that the manual and AI entry paths share
- `src/cli.cr` — executable entry point

## Roadmap

- Interactive REPL wrapping `finfry ai` with retained conversation context (so
  follow-ups like "no, the other card" work)
- AI support for split transactions (multiple categories in one entry)

## Contributing

1. Fork it (<https://github.com/transfire/finfry/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Thomas Sawyer](https://github.com/transfire) - creator and maintainer
