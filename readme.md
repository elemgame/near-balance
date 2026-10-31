<h1 align="center">near-balance</h1>
<p align="center">a simple way to get a NEAR balance report</p>

## Install

Install a reviewed version of [near-cli-rs](https://github.com/near/near-cli-rs)
separately and put its `near` executable on your trusted `PATH`, for example:

```sh
npm install -g near-cli-rs@0.30.1
```

Verify release provenance and integrity before installation. Dependency updates
are explicit maintenance actions; generating a report never installs or updates
packages.

```bash
curl -fsSL https://raw.githubusercontent.com/elemgame/near-balance/main/near-balance.sh \
 -o "${XDG_BIN_HOME:?need set bin path}/near-balance"
chmod +x "${XDG_BIN_HOME}/near-balance"
```
or
```bash
git clone https://github.com/elemgame/near-balance.git && cd near-balance
cp near-balance.sh "${XDG_BIN_HOME:?need set bin path}/near-balance"
```

> [!NOTE]
> Optional, to display the current price, you need to set an environment variable
> `COINMARKETCAP_API_KEY` [get Free API Key](https://coinmarketcap.com/api/dashboard/api-keys/) 

## Usage

```bash
near-balance <account.near> [YYMMDD]
```

### Example
```bash
near-balance elemgame.near

Oct 31, 2026 09:33:52 UTC At block [#222402614 BH3TfMvQqyhrsQdHo2Tvo5GoucEvnGsLFBrpc628oPBQ] (https://nearblocks.io/blocks/222402614)

3667.46508583 $NEAR Oct 31, 2026 09:33:52 UTC

Daily Gain  +0.5111 $NEAR
Annual Gain +186.67 $NEAR
APY                 5.09%

~$15858 [by $4.3239 close price at Oct 30](https://coinmarketcap.com/currencies/near-protocol/historical-data/)
```

## Requirements and checks

Requires Bash, GNU date, awk, sed, and a separately installed `near-cli-rs`.
With `COINMARKETCAP_API_KEY` set, curl 7.55.0 or newer and jq are also required. Without a key (or with an empty key), no price request is made and
the USD line is omitted. If no date is supplied, this is silent. An explicit
date without a key produces a warning on stderr; a valid date still allows the
balance report to complete.

An optional second argument selects the price date: `near-balance elemgame.near 261011`.
It must contain exactly six digits (`YYMMDD`, years 2000–2099), represent a real
calendar date, and be earlier than today in UTC. Invalid, current, and future
dates fail before account or price requests, whether or not an API key is set.
Historical prices require an appropriate CoinMarketCap plan; otherwise the script
falls back to the latest quote. The fallback is a current price, not a historical
closing price. Gains are estimates from cached balances or a baseline 5.09% APY;
balance changes can include deposits and withdrawals.

Install ShellCheck and [bats-core](https://github.com/bats-core/bats-core) 1.5.0 or newer, then run:

```sh
make lint
make test
# Or both:
make check
```

Tests use local command stubs, temporary caches, and a dummy API key. They do not
install near-cli or contact NEAR or CoinMarketCap. CI runs these checks on pushes
to `main` and on non-draft pull requests, including when marked ready for review.
