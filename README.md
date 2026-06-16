# finfry

A small command-line budget & expense tracker written in [Crystal](https://crystal-lang.org),
built on the [Jargon](https://github.com/trans/jargon) CLI shard. No GUI — just
a fast terminal ledger stored as plain JSON.

## Installation

```sh
shards install
shards build --release
```

The `finfry` binary is produced in `./bin`.

## Usage

```sh
# Record expenses (amount is required; description/category/date optional)
finfry add 12.50 "morning coffee" -c food
finfry add 1234.56 rent -c housing -d 2026-06-01

# Record income
finfry add 3000 salary --income

# List transactions (filter by category, month, or count)
finfry list
finfry list -c food
finfry list -m 2026-06 -n 10

# Summarize a month by category (defaults to the current month)
finfry report
finfry report -m 2026-06

# Set monthly budgets and track them against spending
finfry budget set food 400
finfry budget list
finfry budget rm food

# Delete a transaction by its id (shown in `list`)
finfry delete 3
```

Run `finfry --help`, or `finfry <command> --help`, for the full set of options.

### Amounts

Amounts are entered as decimals and may include a `$` and thousands separators
(`$1,234.56`). Internally they are stored as integer cents, so there is no
floating-point rounding error.

### Data storage

The ledger is a single JSON file. By default it lives at:

```
$XDG_DATA_HOME/finfry/data.json   # typically ~/.local/share/finfry/data.json
```

Set the `FINFRY_DATA` environment variable to point at a different file (handy
for keeping separate ledgers or for testing).

## Development

```sh
crystal spec          # run the test suite
shards build          # build a debug binary
crystal tool format   # format the source
```

The code is organized as:

- `src/finfry/money.cr` — parse/format money as integer cents
- `src/finfry/models.cr` — `Transaction` and `Database` records
- `src/finfry/store.cr` — JSON persistence and queries
- `src/finfry/app.cr` — Jargon CLI definition and command handlers
- `src/cli.cr` — executable entry point

## Contributing

1. Fork it (<https://github.com/transfire/finfry/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Thomas Sawyer](https://github.com/transfire) - creator and maintainer
