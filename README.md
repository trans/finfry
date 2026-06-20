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
finfry accounts set Liabilities:CreditCards:Chase apr 19.99   # account metadata (apr, limit, due-day, …)
finfry accounts info Liabilities:CreditCards:Chase           # balance + metadata
finfry accounts unset Liabilities:CreditCards:Chase apr
finfry accounts policy guard            # strict | guard | off (no arg prints current)
```

Accounts can carry free-form **metadata** (`accounts set <account> <key> <value>`)
— e.g. a credit card's `apr`, `limit`, `due-day`, `bank`. It shows in
`accounts list`/`info`, is carried across `rename`, and is visible to the AI so it
can reason about rates and terms. (Secret metadata — account numbers etc. kept
out of the AI's view — is a planned follow-up; for now treat metadata as
non-secret.)

The AI path respects the policy too: a proposal that introduces a new account
shows it as `New account: …`, and your confirmation is the deliberate "yes" that
declares it — even in strict mode.

### Undo & corrections

There are two ways to take something back, matching how bookkeeping actually
works:

- **`finfry undo`** removes the **most recent** change outright — as if it never
  happened. Safe because nothing has been recorded on top of it yet (like
  backspacing before it's part of the record). Repeated `undo` pops back through
  recent changes.
- **`finfry undo <id>`** corrects an **older** change (find the id with
  `finfry history`) by posting a **reversing entry** — a mirror-image
  transaction (`Reversal of #N`) so the two net to zero. The original is kept
  and the audit trail is preserved, because you can't un-happen history that
  later entries sit on top of.

`finfry redo` brings back the change `undo` just removed (single level; any new
change invalidates it). `finfry history` lists changes and marks which have been
reversed.

### Recurring entries

Define a recurring commitment, and finfry generates a **queue of due occurrences**
you review and approve — nothing posts automatically.

```sh
finfry recurring add 15.49 Expenses:Subscriptions:Netflix -m Netflix -e monthly
finfry recurring add 1200 Expenses:Housing -m Rent -e monthly --from Assets:Savings
finfry recurring list
finfry recurring off 2          # stop generating new occurrences
```

`recurring add` works for expenses, income (`--kind income`), or transfers
(`--kind transfer`), with `--every <cadence>` and an optional `--start` date
(back-date it to catch up missed cycles).

**Credit-card interest** is a rule whose amount is *computed* each cycle from the
card's `apr` metadata applied to what's owed:

```sh
finfry accounts set Liabilities:CreditCard apr 19.99   # (or pass --apr below)
finfry recurring interest Liabilities:CreditCard --every monthly
```
Each cycle, `due` shows the computed charge (`apr × balance owed`, for that
cadence's slice of the year) for you to review/adjust/post like any other; if
nothing's owed, no charge is generated.

Then review what's due and apply it in a stage-then-post cycle:

```sh
finfry due                      # list due occurrences (catches up since last time)
finfry due ok 1 3               # stage entries to post (or: due ok all)
finfry due skip 2               # stage to drop (won't reappear)
finfry due edit 4 --amount 64.20  # adjust a variable bill (marks it ok)
finfry due reset 3              # clear a staged decision back to pending
finfry due post                 # apply: post the ok'd, drop the skipped
```

Unstaged entries just stay pending for next time. Each posted occurrence is a
normal [undoable](#undo--corrections) transaction (tagged with its cadence, so it
shows in `report daily`).

### Reconciliation

Reconciling proves your ledger agrees with a bank or card statement. It works in
two tiers, per account (so checking and a credit card reconcile independently) —
the same stage-then-commit shape as [`due`](#recurring-entries):

- **cleared** — *staged.* "I think this hit the bank." You toggle it while
  working through the statement; it stays visible and is freely reversible.
- **reconciled** — *committed.* Locked in by a finished, statement-balanced
  reconciliation. These drop off the working list.

```
finfry reconcile Assets:Checking                 # working list + cleared/ledger balances
finfry reconcile Assets:Checking clear 1 2       # stage: mark transactions that hit the statement (or 'all')
finfry reconcile Assets:Checking unclear 2       # unstage (or 'all')
finfry reconcile Assets:Checking balance 2738.00 # check cleared balance against the statement total
finfry reconcile Assets:Checking commit 2738.00  # finalize (only if it balances)
```

The account always comes first — every form is `reconcile <account> <action> …`,
where each action owns its trailing argument: `clear`/`unclear` take ids,
`balance`/`commit` take the statement balance. (Keeping that slot a fixed set of
verbs means a forgotten action — `reconcile A 1 2` — fails loudly instead of
misreading `1` as a balance.) The status view lists every not-yet-reconciled
transaction touching the account, marking staged-cleared ones with `*`, alongside
the **cleared balance** (reconciled + staged — what should match a statement) and
the full **ledger balance**. `balance <amount>` tells you whether they agree or
are **off by** some amount.

`commit` finalizes: it locks the staged transactions into the reconciled tier —
but only if the cleared balance matches the statement, so you can never reconcile
to a wrong number. Each commit is stamped (date + statement) for the audit trail
and shown as "last reconciled" thereafter.

Clearing and committing are bookkeeping metadata, not ledger changes — they never
alter balances. The AI can *read* reconciliation status, but staging and
committing stay a human, statement-in-hand task.

### Sign convention

Amounts are signed cents internally. `Assets`/`Expenses` are debit-normal
(positive), `Income`/`Liabilities`/`Equity` are credit-normal. Reports flip the
sign on credit-normal accounts so they read as positive numbers.

## Usage

### AI assistant

`finfry ai` lets you ask questions or make changes in plain English. Under the
hood every finfry command is exposed to Claude as a tool, so it can read the
ledger to answer you and propose changes for you to approve.

```sh
export ANTHROPIC_API_KEY=sk-ant-...

# Ask — read-only, answered directly
finfry ai "what did I spend on food last month?"

# Record — one or many changes, gathered into a plan you approve
finfry ai "spent $50 at Starbucks yesterday on my Chase Platinum CC"
finfry ai "set next month's food budget 10% under what I spent in May"
echo "netflix 15.49 monthly" | finfry ai --yes
```

How it works:

- **Read tools** (`register`, `balance`, `report`, `balance-sheet`, `daily`,
  `accounts`, `history`, `recurring`, `due`, `reconcile`) run immediately so the
  AI can answer and gather context.
- **Write tools** (`spend`, `earn`, `transfer`, `budget`, `accounts add/rename`,
  `recurring add/interest/off`, `due ok/skip/edit/post`) don't take effect right
  away — they're collected into a **plan** that finfry
  shows you and applies only once you approve it (`--yes` skips the prompt).
  The whole plan applies as one [undoable](#undo--corrections) change.
- It reuses your existing accounts for consistency and resolves relative dates.
  finfry assembles the balanced postings and enforces the account policy, so the
  AI can't throw off the books. `delete` and `accounts policy` are withheld from
  the AI on purpose.

Set `FINFRY_MODEL` to override the model (default `claude-opus-4-8`).

### Use finfry inside an agent harness (MCP)

`finfry mcp` runs finfry as an [MCP](https://modelcontextprotocol.io) server over
stdio, exposing the same safe command surface as tools so any MCP client (Claude
Code, Claude Desktop, …) can read and update the ledger — with the harness
providing the chat, history, and approval UI.

The easiest path is `finfry init` (above) — it writes a `.mcp.json` into the book
directory, so any MCP client opened there picks up a `finfry` server pinned to
that book automatically. To register one manually instead (standard config
shape):

```json
{
  "mcpServers": {
    "finfry": { "command": "finfry", "args": ["mcp"] }
  }
}
```

Or with the Claude Code CLI — note the scopes: `--scope project` writes a shared
`.mcp.json` in the directory (what `finfry init` does), `--scope local` is a
private per-directory entry in your user config, and `--scope user` is global:

```sh
claude mcp add finfry --scope project -- finfry mcp
```

Notes:
- The client (not finfry) gates each tool call, so writes execute when invoked —
  each still records its own [undoable](#undo--corrections) change, and the
  account policy + balance guards still apply.
- `delete` and `accounts policy` are not exposed over MCP (same withholding as the
  built-in agent).
- Set `FINFRY_DATA` in the server's env if you want it pointed at a specific
  ledger.

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
finfry register [-a Expenses:Food] [-m 2026-06] [-n 10]   # transactions (the ledger register)
finfry register -s 2026-06-01 -u 2026-06-30 --min 100  # filter by date range / amount...
finfry register -q rent                                # ...or memo text (--match)
finfry balance [Assets]                                # account balances (quick lookup)
finfry report                                          # income statement (default)
finfry report income [-m 2026-06]                      # income statement
finfry report balance-sheet [-d 2026-06-30]            # balance sheet + integrity check
finfry report daily                                    # per-day cost of recurring items
finfry report balance [Assets]                         # account balances (also under report)
finfry accounts                                        # accounts in use
finfry history [-n 10]                                 # change history
finfry undo                                            # remove the most recent change
finfry undo 4                                          # reverse an older change (correcting entry)
finfry redo                                            # bring back the change undo just removed
finfry init [dir]                                      # create a per-directory book
finfry path                                            # print the active ledger file

# Reconcile an account against a bank/card statement (account always comes first)
finfry reconcile Assets:Checking                       # working list + cleared/ledger balances
finfry reconcile Assets:Checking clear 1 2 5           # stage transactions as cleared (or 'all')
finfry reconcile Assets:Checking unclear 5             # unstage (or 'all')
finfry reconcile Assets:Checking balance 2738.00       # check cleared balance against the statement
finfry reconcile Assets:Checking commit 2738.00        # finalize (locks staged, only if it balances)

# Budgets (per account, rolled up over the subtree)
finfry budget set Expenses:Food 400
finfry budget list
finfry budget rm Expenses:Food

# Delete a transaction by id (shown in `register`)
finfry delete 3
```

Run `finfry --help`, or `finfry <command> --help`, for full options.

### Recurring items & daily cost

Tag a transaction with `-r <cadence>` to mark it recurring. `finfry report daily` then
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

### Data storage & books

A ledger is a single JSON file. finfry finds the active one by, in order:

1. **`FINFRY_DATA`** — an explicit path override.
2. **The nearest `finfry.json`** found by walking up from the current directory
   (like git's `.git`) — this is a per-directory *book*.
3. **The global ledger** at `$XDG_DATA_HOME/finfry/data.json` (typically
   `~/.local/share/finfry/data.json`).

`finfry path` prints whichever is active.

Create a per-directory book with `finfry init` (defaults to the current
directory; pass a path to use another):

```sh
mkdir ~/finances && cd ~/finances && finfry init
# Initialized finfry book at /home/you/finances/finfry.json
# Wrote /home/you/finances/.mcp.json (finfry MCP server pinned to this book)
```

Running finfry anywhere under that directory then uses that book. `init` also
writes a **`.mcp.json`** registering a `finfry` [MCP](#use-finfry-inside-an-agent-harness-mcp)
server pinned to that book — so an MCP client (Claude Code, …) opened in that
directory gets AI access to *that book only*, with no per-book setup. (Pass
`--no-mcp` to skip it; an existing `.mcp.json` is merged, not overwritten.)
Without a book in scope, finfry uses the global ledger, so casual single-book use
still works anywhere.

Writes are atomic (temp file + rename), and an older single-entry ledger is
migrated to double-entry on first load (the original is kept as a `.bak`).

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
- `src/finfry/ai.cr` — the `Finfry::AI` seam: a tool-use conversation loop over
  the Claude API (raw HTTP, no SDK); swappable behind one module
- `src/finfry/mcp.cr` — a stdio MCP server exposing the safe command surface as
  tools, reusing the same registry and executor as the built-in agent
- `src/finfry/app.cr` — Jargon CLI definition and command handlers; the shared
  `commit`/`render`/`postings_for` core that the manual and AI entry paths share
- `src/cli.cr` — executable entry point

## Roadmap

- A lightweight built-in chat fallback (a thin REPL over `finfry ai`) for when no
  external harness is available
- AI support for split transactions (multiple categories in one entry)

## Contributing

1. Fork it (<https://github.com/transfire/finfry/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Thomas Sawyer](https://github.com/transfire) - creator and maintainer
