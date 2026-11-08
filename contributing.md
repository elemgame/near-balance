# Contributing

See [readme.md](readme.md) for installation and usage

## Checks and pull requests

```sh
make quality-bash
```

## Configuration and data

Parse only `mainnet` from both output streams of `near --quiet config show-connections`, preserving RPC URLs containing `archival-rpc`

Otherwise persist the default through `config edit-connection`, stopping on configuration errors

Combine native and validator balances from `view-account-summary` with FastNEAR-discovered pool totals from `get_account_total_balance` at the same block

Include unstaked funds without counting delegated stake twice or calculating per-pool APY

Search timestamps for a block within one hour before the 30-day target, tolerate skipped heights, and verify the historical summary matches

Incomplete current data must fail, while unavailable history yields `N/A`

## Formulas

Use current balance `B`, previous balance `P`, elapsed days `d`, and signed external flows `F` weighted by the remaining fraction of the interval `w`

```text
R           = (B - P - sum(F)) / (P + sum(F * w))
APY (%)     = ((1 + R)^(365 / d) - 1) * 100
Daily Gain  = B * ((1 + R)^(1 / d) - 1)
Annual Gain = B * ((1 + R)^(365 / d) - 1)
```

Use the Modified Dietz approximation with complete NearBlocks receipt history between the pinned blocks, using `/receipts` filtered by execution dates, following every cursor to the terminal page and deduplicating receipt IDs

Count successful external transfers and attached call deposits, excluding self transfers, discovered staking pools, and system refunds

Unavailable or invalid history, unsupported account deletions, and weighted capital at or below the eight decimal balance precision yield `N/A` without falling back to unadjusted balance growth

These are estimates of total account growth after fees and other balance effects, not a guaranteed staking yield, and depend on the indexer having complete receipt data

Keep zero and negative adjusted growth, treating residuals below the eight decimal balance precision as zero

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
