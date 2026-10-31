# Contributing

See [readme.md](readme.md) for installation and usage

## Checks and pull requests

Requires util-linux `script` for terminal tests, ShellCheck, jq, and [bats-core](https://github.com/bats-core/bats-core) 1.5.0+

```sh
# Install tools through sudo apt-get on Debian or Ubuntu
make toolchain
make lint
make test
# Run both checks
make qa
```

Add regression tests in `tests/report.bats` with offline command stubs in `tests/helpers/`

Tests use temporary state without changing real configuration

CI runs `Lint and test` on main pushes and non-draft PRs, including ready-for-review events

Main requires a PR and successful checks, with force pushes and deletion disabled

## Configuration and data

Parse only `mainnet` from both output streams of `near --quiet config show-connections`, preserving RPC URLs containing `archival-rpc`

Otherwise persist the default through `config edit-connection`, stopping on configuration errors

Combine native and validator balances from `view-account-summary` with FastNEAR-discovered pool totals from `get_account_total_balance` at the same block

Include unstaked funds without counting delegated stake twice or calculating per-pool APY

Search timestamps for a block within one hour before the 30-day target, tolerate skipped heights, and verify the historical summary matches

Incomplete current data must fail, while unavailable history yields `N/A`

## Formulas

Use current balance `B`, previous balance `P`, and actual elapsed days `d`

```text
APY (%)     = ((B / P)^(365 / d) - 1) * 100
Daily Gain  = B * ((B / P)^(1 / d) - 1)
Annual Gain = B * ((B / P)^(365 / d) - 1)
```

Zero `P` yields `N/A`, while zero `B` with positive `P` yields -100% APY and zero projected gains

Preserve zero and negative growth without fixed rates

Transfers and fees affect these estimates because cash flows are not reconstructed

## Dependencies and formatting

Review dependency updates separately without installing packages during report generation

The `format URL TEXT` helper selects OSC 8 or Markdown at startup so command substitutions preserve terminal formatting

## Prices

Use public Coinbase Exchange `NEAR-USD` endpoints without authentication

Request `candles` with `granularity=86400`, UTC midnight `start`, and next midnight `end`, selecting exactly one candle with the requested timestamp and a positive finite numeric close

Use `ticker.price` for `now`, validating its decimal string as a positive finite number

Reject invalid or unfinished dates before network calls and test missing data, malformed responses, network errors, and date boundaries

## History cache

Store verified mainnet snapshots atomically with account, block height, hash, timestamp, and total balance in `$HOME/.near-balance/<account>-history.json`

Reuse the nearest snapshot aged 30 to 31 days and recalculate growth with the current balance and actual elapsed time

Keep up to 64 recent snapshots and ignore malformed, foreign, or expired cache data without making cache writes mandatory

Retry current block validation and missing historical snapshots up to five times with two second pauses, limiting each RPC or historical CLI request to 20 seconds
