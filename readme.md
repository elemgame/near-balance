<h1 align="center">near-balance</h1>
<p align="center">NEAR balance and estimated growth from 30-day history</p>

## Install

Requires internet access, Bash, GNU date, awk, sed, jq, curl 7.55.0+, and [near-cli-rs](https://github.com/near/near-cli-rs) on `PATH`

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
near-balance <account.near> [YYMMDD]
```

> [!NOTE]
> Optional, to display the current price, you need to set an environment variable
> `COINMARKETCAP_API_KEY` [get Free API Key](https://coinmarketcap.com/api/dashboard/api-keys/)

### Example

```bash
near-balance elemgame.near
Oct 31, 2026 11:23:49 UTC At block #222413833 DpK7iV8RBK9QqsWg3KHMgemCXusyzLcUse9CnHqLmEmd

3667.56177707 $NEAR Oct 31, 2026 11:23:49 UTC

Daily Gain  +0.4822 $NEAR
Annual Gain +180.28 $NEAR
APY         4.92%

~$15867 by $4.3263 close price at Oct 30
```

See [contributing.md](contributing.md) for development and formulas
