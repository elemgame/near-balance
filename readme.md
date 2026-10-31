<h1 align="center">near-balance</h1>
<p align="center">NEAR balance and estimated growth from 30-day history</p>

## Install

Requires internet access, Bash, GNU date, timeout, awk, sed, jq, curl, and [near-cli-rs](https://github.com/near/near-cli-rs) on `PATH`

```bash
npm install -g near-cli-rs@0.30.1
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
> The script persistently sets the near-cli `mainnet` RPC to `https://archival-rpc.mainnet.fastnear.com/` unless its URL already contains `archival-rpc`

## Usage

```bash
near-balance <account.near> [now|YYMMDD]
```

Prices use Coinbase NEAR-USD

- Omit the date for yesterday's UTC candle close
- Use `now` for the latest trade price
- Use `YYMMDD` for a valid past UTC date's close

### Example

```bash
near-balance elemgame.near
Oct 31, 2026 15:40:39 UTC At block #222439918 2A9X7MpnJtQu88g4wQgKQpwes3eCeGD14SJC8o5dWJJr

3667.60172352 $NEAR Oct 31, 2026 15:40:39 UTC

Daily Gain  +0.4822 $NEAR
Annual Gain +180.30 $NEAR
APY         4.92%

~$15721 by $4.2864 close price at Oct 30, 2026 UTC on Coinbase
```

See [contributing.md](contributing.md) for development and formulas
