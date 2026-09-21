# The log is the book — a log-first store for finfry

*Design draft, 2026-09-21. Not yet built.*

## The idea in one paragraph

Today `finfry.json` is the truth and every command rewrites it in place; a
changeset journal *inside* the file gives undo. This proposes the Delta Lake
shape instead: an **append-only log of commits** is the truth, each commit an
atomic set of small **actions**; the current state is the **fold** of the log;
`finfry.json` becomes a **checkpoint** — a cache of the fold, regenerable at
any time. Backup, history, undo, time travel, audit and crash safety all fall
out of one mechanism instead of four bolted-on ones. The log is a C0DATA
stream-mode file, which is exactly what stream mode was specified for.

## What a book is

    ~/finances/
      finfry.log      the truth: commits, append-only (C0 stream mode)
      finfry.json     checkpoint: the fold as of commit N (regenerable)
      .mcp.json       unchanged

`FINFRY_DATA`, book discovery (`finfry.json` walking up) and the global
ledger keep working: the log sits next to the checkpoint with the same base
name (`data.json` → `data.log`). Delete `finfry.json` and the next command
rebuilds it from the log. Delete the log and you have a checkpoint with no
history — a plain book, like today.

## Commits and actions

One commit per `Store#changeset` (which is already every command's
transaction boundary). One ETB block per commit, so a commit is atomic on
disk: a crash mid-write leaves a torn tail the reader skips and the next
writer truncates. The first record of a block is the commit itself; the
rest are its actions, positional records typed by their first field:

    ␞commit␟39␟2026-09-21 16:26␟cli␟Market run ($48.20)
    ␞record␟41␟2026-09-03␟Market run␟␟␂Expenses:Food:Groceries␟4820␟Assets:Checking␟-4820␃
    ␗

Fields: `commit seq at origin summary` (origin: cli / web / ai / mcp — who
did it, for the audit and for the AI-first story). Amounts are integer cents
as text; lists are STX/ETX-nested; empty field = nil.

### The action vocabulary

Derived from every mutation `Store` has today (plus the two the App does
in place on `DueEntry`). Each is a *record of an effect*, never an intent:
the fold applies effects; it never recomputes anything time-dependent.

| Action | Fields | Today's method |
|---|---|---|
| `record` | id date description recurrence postings | `record` |
| `remove` | id | `delete_transaction` |
| `revert` | seq | `undo_last` (see Undo) |
| `unrevert` | seq | `redo_last` |
| `budget` / `unbudget` | account limit / account | `set_budget` / `remove_budget` |
| `declare` / `undeclare` | name | `declare_account` / `undeclare_account` |
| `rename` | from to | `rename_account` |
| `meta` / `unmeta` | account key value / account key | `set_account_meta` / `unset_account_meta` |
| `setting` | key value | `set_account_policy`, the `example` flag |
| `clear` / `unclear` | account ids… | `set_cleared` |
| `reconcile` | account statement date statement_date ids… | `reconcile!` |
| `rule` | id description cadence next_date kind active postings | `add_recurring_rule` |
| `rule-off` | id | `deactivate_rule` |
| `rule-next` | id next_date | cursor advance inside `generate_due` |
| `due` | id rule_id date description cadence status postings | `generate_due` (one per occurrence) |
| `due-status` | id status | `e.status = …` (App) |
| `due-edit` | id date description postings | `due edit` (App) |
| `due-remove` | ids… | `remove_due_entries` |

Computed things — the interest charge a rule produces, the occurrences a
cadence yields — are computed **once, at commit time**, and logged as `due`
actions. Replay is therefore deterministic and independent of the clock.

### Every mutation is a commit

Today only ledger changes are journaled; cleared marks, due staging, metadata
and rules just `save`. In the log everything is a commit (it must be — there
is no other way to write). Commits carry a `kind`: `ledger` (touches
transactions/budgets/accounts — what `history` shows today) or
`bookkeeping` (cleared, due, rules, meta). `finfry history` keeps showing
ledger commits; `history --all` shows everything.

## The fold

`Database` stays exactly as it is — it *is* the fold's state. Each action
is a small function `Database → Database`; the fold is `log.each_commit
.reject(&.reverted?).each_action { |a| apply(db, a) }`. Reads (`balances`,
`register`, the whole query layer) don't change at all: they read the
`Database` as they do now.

## Undo, redo, reverse

- `undo` (pop the latest) becomes a `revert seq` commit: the log never loses
  anything; the fold skips reverted commits. `redo` is `unrevert`. Redo
  stays single-level in the UI, but the log has no such limit.
- `undo <id>` (correcting entry for an older change) is unchanged: a normal
  `record` commit whose summary says `Reversal of #N`.
- Transaction ids are **never reused**. Today `undo_last` resets `next_id`;
  after a revert the next entry gets the next id. More honest, and required
  for the log to be unambiguous.

## Checkpoint

`finfry.json` = the fold plus `version: <seq of last applied commit>`.
Written after every commit for now (it's what today's `save` costs; cheap).
On open: load the checkpoint, then apply any commits in the log past its
version — so a checkpoint that's behind (another process appended; the
writer crashed between append and checkpoint) is just caught up. A missing
or unparsable checkpoint means a full fold. Checkpoint cadence can go to
"every N commits" later without changing anything else.

## Multiple writers (CLI + `serve` + MCP)

Appends are atomic blocks and every writer repairs-then-appends, so
concurrent processes can't corrupt the log. `Store#refresh` stops comparing
mtimes and instead applies commits past its own version — exact and cheap.
Two processes committing at the same instant: an advisory lock (`flock`) on
the log around append + checkpoint. Sequence numbers are assigned under the
lock, so they are dense and ordered.

## What you get for free

- **Backup** — the whole question dissolves: the log is append-only and the
  book directory *is* the backup. Copy it, sync it, `git add` it, whatever
  you already do for documents.
- **Time travel** — `finfry as-of 38` folds to commit 38 (report, or write a
  checkpoint elsewhere to poke at). "The books as they were before that
  import."
- **Diff** — what changed between 38 and 45 is *the actions between them*;
  no snapshot comparison, no algorithm. Rendering them readably is the
  whole feature.
- **Audit** — every change has when, who (origin) and why (summary). The AI
  path gets `ai` as origin and its plan text as the summary.
- **Crash safety** — a torn block is skipped, never folded in.
- **Verification** — `finfry verify` folds the log and compares to the
  checkpoint.

## The `keep` shard

The generic layer, ledger-agnostic — "a Delta log for a file":

    log = Keep::Log.open("finfry.log")
    log.append(at: now, origin: "cli", summary: "…", kind: "ledger") do |c|
      c.action("record", id, date, desc, recurrence, postings)
    end
    log.each_commit(after: version) { |commit| … }   # commit.seq/at/origin/summary/kind/reverted?/actions
    log.fold(state, after: version) { |state, action| apply(state, action) }
    log.as_of(seq) …
    Keep.checkpoint(path, state, version) / Keep.load_checkpoint(path)
    log.lock { … }                                    # flock for append + checkpoint

It knows commits, actions as positional string records, revert marks,
locking, repair, versions. finfry supplies the action vocabulary, the
`apply`, and the `Database`. Lives at `~/my/com/tabcomputing/keep`
(`github.com/tabcomputing/keep`), depends on `c0` (whose `jargon` pin must
move to `>= 0.20` so finfry → keep → c0 resolves).

## Migration from today's files

On first open of a `finfry.json` with no `finfry.log` beside it:

1. For each existing changeset that added transactions, emit one commit
   (same seq, `at`, summary; `record` actions for its transactions; a
   reverted one for anything `undo` removed isn't recoverable — those are
   simply absent, as today).
2. One final `migrated` commit carrying everything else as actions:
   budgets, declared accounts, metadata, settings, cleared/reconciled sets
   and reconciliations, rules, due entries.
3. Write the checkpoint with `version` = last seq. The original file is
   kept as `finfry.json.pre-log` (superseding the old `.bak` migration).

The fold of the new log reproduces the old `Database` exactly; that is the
migration's test.

## Not in this design

- Delta-compressed snapshots (there are no snapshots).
- A C0 "file delta" standard. The action records are finfry's schema; if a
  second application (transfs?) wants the same commit/action shape, the
  *commit framing* — `commit` record + typed action records per ETB block —
  is the candidate for a `c0-spec/notes/` proposal. Not before.
- Multi-book or remote sync. The log makes them tractable later (append
  from elsewhere = merge), but nothing here depends on it.

## Order of work

1. `keep` — the shard, with specs: append/repair/lock, commits and actions,
   fold, checkpoint, as-of, torn-tail cases. (`c0` jargon pin first.)
2. finfry `Store` on `keep`: actions for every mutation, the fold, the
   checkpoint; `refresh` by version; `next_id` never reused. The whole
   existing spec suite must pass unchanged — the read API doesn't move.
3. Migration + `finfry.json.pre-log`; run it on the real books.
4. `finfry log` / `as-of` / `verify` / `diff`, and the History page showing
   commits with their actions.
5. Then the stage, then import — both now land on a store that records
   who did what and why, which is what the AI-first principle needed.
