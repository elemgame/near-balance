# Contributing

See [readme.md](readme.md) for installation and usage

## Checks and pull requests

Requires ShellCheck, jq, and [bats-core](https://github.com/bats-core/bats-core) 1.5.0+

```sh
# Install tools through sudo apt-get on Debian or Ubuntu
make toolchain
make lint
make test
# Run both checks
make qa
```

Add regression tests in `tests/report.bats` with offline command stubs in `tests/helpers/`

Tests use temporary state and dummy credentials without changing real configuration

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

Preserve zero and negative growth without fixed rates or cached balances

Transfers and fees affect these estimates because cash flows are not reconstructed

## Dependencies and credentials

Review dependency updates separately without installing packages during report generation

Remove the CMC key from child environments and pass headers through stdin, preserving credential-exposure and header-injection tests
