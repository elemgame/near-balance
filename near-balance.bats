#!/usr/bin/env bats
setup_file() {
    mkdir -p "$BATS_FILE_TMPDIR/helpers"
    cat > "$BATS_FILE_TMPDIR/helpers/curl" <<'HELPER_CURL'
#!/usr/bin/env bash
set -eu
if [[ "$*" == *api.nearblocks.io* ]]; then
    printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/flows.calls"
    [[ "${FLOW_FAILURE:-}" != 1 ]] || exit 28
    if [[ "$*" == *cursor=123* ]]; then
        printf '%s\n' "${FLOW_SECOND:-}"
    else
        if [[ -n "${FLOW_RESPONSE:-}" ]]; then
            printf '%s\n' "$FLOW_RESPONSE"
        else
            printf '%s\n' '{"txns":[]}'
        fi
    fi
    exit
fi
if [[ "$*" == *api.fastnear.com/v1/account/* ]]; then
    if [[ "${POOL_DISCOVERY_FAILURE:-}" == 1 ]]; then exit 1; fi
    if [[ "${NO_POOLS:-}" == 1 ]]; then
        printf '%s\n' '{"account_id":"example.near","pools":[]}'
        exit
    fi
    printf '%s\n' '{"account_id":"example.near","pools":[{"pool_id":"pool.near"}]}'
    exit
fi
if [[ "$*" == *archival-rpc.mainnet.fastnear.com* ]]; then
    if [[ "${RPC_FAILURE:-}" == 1 ]]; then exit 1; fi
    while [[ "$1" != --data ]]; do shift; done
    height=$(printf '%s' "$2" | jq -r '.params.block_id')
    printf '%s\n' "$height" >> "$BATS_TEST_TMPDIR/blocks.calls"
    if [[ "${SKIPPED_BLOCK:-}" == 1 && "$height" == 111192670 ]]; then
        printf '%s\n' '{"error":{"cause":{"name":"UNKNOWN_BLOCK"}}}'
        exit
    fi
    timestamp=$((1793400000 - (222385340 - height) * ${BLOCK_SECONDS:-1}))
    jq -cn --argjson height "$height" --arg timestamp "${timestamp}000000000" \
        '{result:{header:{height:$height,timestamp_nanosec:$timestamp,hash:"3LbJoQaZCUskZYKfeUoDMbxEqH4pvp3rmmY4avdKvE8G"}}}'
    exit
fi
printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/curl.calls"
[[ "$*" == *https://api.exchange.coinbase.com/products/NEAR-USD/* ]] || exit 97
[[ "$*" != *'-H '* ]] || exit 93
[[ "${PRICE_NETWORK_FAILURE:-}" != 1 ]] || exit 28
if [[ -n "${PRICE_RESPONSE:-}" ]]; then
    printf '%s\n' "$PRICE_RESPONSE"
elif [[ "$*" == */ticker* ]]; then
    printf '%s\n' '{"price":"3.25","bid":"3.24","ask":"3.26"}'
else
    day=''
    for arg in "$@"; do
        if [[ "$arg" == start=* ]]; then day="${arg#start=}"; fi
    done
    timestamp=$(date -u -d "$day" +%s)
    jq -cn --argjson timestamp "$timestamp" '[[$timestamp,1,3,1.5,2,100]]'
fi
HELPER_CURL
    cat > "$BATS_FILE_TMPDIR/helpers/date" <<'HELPER_DATE'
#!/usr/bin/env bash
# Freeze the default price day without changing other date operations
if [[ -n "${TEST_TODAY:-}" && "$*" == '-u -d yesterday +%Y-%m-%d' ]]; then
    command -p date -u -d "$TEST_TODAY -1 day" +%Y-%m-%d
else
    command -p date "$@"
fi
HELPER_DATE
    cat > "$BATS_FILE_TMPDIR/helpers/near" <<'HELPER_NEAR'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/near.calls"
if [[ "$*" == *'config show-connections'* ]]; then
    [[ "${CONFIG_READ_FAILURE:-}" != 1 ]] || exit 1
    rpc="${CONFIG_RPC-https://archival-rpc.mainnet.fastnear.com/}"
    if [[ -f "$BATS_TEST_TMPDIR/config.rpc" ]]; then
        rpc=$(cat "$BATS_TEST_TMPDIR/config.rpc")
    fi
    cat >&2 <<CONFIG
[network_connection.testnet]
rpc_url = "https://archival-rpc.testnet.fastnear.com/"
[network_connection.mainnet]
rpc_url = "$rpc"
[network_connection.mainnet-fastnear]
rpc_url = "https://rpc.mainnet.fastnear.com/"
CONFIG
    exit
fi
if [[ "$*" == *'config edit-connection'* ]]; then
    [[ "${CONFIG_WRITE_FAILURE:-}" != 1 ]] || exit 1
    [[ "$*" == '--quiet config edit-connection mainnet --key rpc_url --value https://archival-rpc.mainnet.fastnear.com/' ]] || exit 96
    printf '%s\n' "${*: -1}" > "$BATS_TEST_TMPDIR/config.rpc"
    exit
fi
if [[ "$*" == *get_account_total_balance* ]]; then
    [[ "${POOL_QUERY_FAILURE:-}" != 1 ]] || exit 1
    # Include unstaked funds in the same total as active stake
    printf '"%s"\n' "${POOL_TOTAL_YOCTO:-6500000000000000000000000}"
    exit
fi
height="${CURRENT_BLOCK:-222385340}"
native="${CURRENT_NATIVE:-12.5}"
validator="${CURRENT_VALIDATOR:-1}"
if [[ "$*" == *at-block-height* ]]; then
    if [[ -n "${HISTORY_FAIL_COUNT:-}" ]]; then
        attempts=0
        if [[ -f "$BATS_TEST_TMPDIR/history.attempts" ]]; then
            read -r attempts < "$BATS_TEST_TMPDIR/history.attempts"
        fi
        attempts=$((attempts + 1))
        printf '%s\n' "$attempts" > "$BATS_TEST_TMPDIR/history.attempts"
        if (( attempts <= HISTORY_FAIL_COUNT )); then exit 1; fi
    fi
    [[ "${HISTORICAL_FAILURE:-}" != 1 ]] || exit 1
    height="${*: -1}"
    native="${OLD_NATIVE:-12.3}"
    validator="${OLD_VALIDATOR:-1}"
    if [[ "${WRONG_OLD_BLOCK:-}" == 1 ]]; then height=1; fi
fi
cat >&2 <<REPORT
example.near At block #$height
(3LbJoQaZCUskZYKfeUoDMbxEqH4pvp3rmmY4avdKvE8G)
Native account balance $native NEAR
Validator stake $validator NEAR
Delegated stake with <pool.near> 6.5 NEAR
REPORT
HELPER_NEAR
    cat > "$BATS_FILE_TMPDIR/helpers/npm" <<'HELPER_NPM'
#!/usr/bin/env bash
printf '%s\n' 'Unexpected npm invocation' >&2
exit 99
HELPER_NPM
    cat > "$BATS_FILE_TMPDIR/helpers/sleep" <<'HELPER_SLEEP'
#!/usr/bin/env bash
printf "%s\n" "$*" >> "$BATS_TEST_TMPDIR/sleep.calls"
HELPER_SLEEP
    chmod +x "$BATS_FILE_TMPDIR/helpers/"*
}

setup() {
    bats_require_minimum_version 1.5.0
    export PATH="$BATS_FILE_TMPDIR/helpers:$PATH"
    export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
    unset NO_COLOR PRICE_NETWORK_FAILURE TEST_TODAY
    unset PRICE_RESPONSE HISTORICAL_FAILURE RPC_FAILURE
    unset CURRENT_BLOCK
    unset CURRENT_NATIVE OLD_NATIVE POOL_TOTAL_YOCTO POOL_QUERY_FAILURE POOL_DISCOVERY_FAILURE
    unset CURRENT_VALIDATOR OLD_VALIDATOR WRONG_OLD_BLOCK SKIPPED_BLOCK BLOCK_SECONDS NO_POOLS
    unset CONFIG_RPC CONFIG_READ_FAILURE CONFIG_WRITE_FAILURE NEAR_BALANCE_RPC_URL
    export HOME="$BATS_TEST_TMPDIR/home"
    unset FLOW_RESPONSE FLOW_SECOND FLOW_FAILURE
    unset HISTORY_FAIL_COUNT
    SCRIPT="$BATS_TEST_DIRNAME/near-balance.sh"
}

@test "missing account and excess arguments print usage" {
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == Usage:* ]]
    run bash "$SCRIPT" example.near now extra
    [ "$status" -eq 1 ]
}
@test "default price uses yesterday UTC without credentials" {
    export TEST_TODAY=2026-10-31
    run --separate-stderr bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [[ "$output" == *'~$40 [by $2.0000 close price at Oct 30, 2026 UTC on Coinbase]'* ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/curl.calls")" == *'granularity=86400 --data-urlencode start=2026-10-30T00:00:00Z --data-urlencode end=2026-10-31T00:00:00Z'* ]]
}
@test "now uses last trade price rather than bid ask or candle" {
    run --separate-stderr bash "$SCRIPT" example.near now
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [[ "$output" == *'~$65 [by $3.2500 current price on Coinbase]'* ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/curl.calls")" == */ticker ]]
    [[ "$output" != *'close price'* ]]
}
@test "explicit dates include leap days and year boundaries" {
    for day in 240229 251231; do
        run --separate-stderr bash "$SCRIPT" example.near "$day"
        [ "$status" -eq 0 ]
        [ -z "$stderr" ]
    done
    [[ "$(cat "$BATS_TEST_TMPDIR/curl.calls")" == *'start=2024-02-29T00:00:00Z --data-urlencode end=2024-03-01T00:00:00Z'* ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/curl.calls")" == *'start=2025-12-31T00:00:00Z --data-urlencode end=2026-01-01T00:00:00Z'* ]]
}
@test "invalid and incomplete dates fail before network requests" {
    for day in '' 26121 2612121 abcdef 260229 261332 261131 NOW "$(date -u +%y%m%d)" "$(date -u -d tomorrow +%y%m%d)"; do
        run --separate-stderr bash "$SCRIPT" example.near "$day"
        [ "$status" -eq 1 ]
        [[ "$stderr" == Error:* ]]
        [ -z "$output" ]
        [ ! -e "$BATS_TEST_TMPDIR/near.calls" ]
        [ ! -e "$BATS_TEST_TMPDIR/curl.calls" ]
    done
}
@test "missing near fails without attempting package installation" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    ln -s "$BATS_FILE_TMPDIR/helpers/npm" "$BATS_TEST_TMPDIR/bin/npm"
    run env PATH="$BATS_TEST_TMPDIR/bin" /bin/bash "$SCRIPT" example.near
    [ "$status" -eq 1 ]
    [[ "$output" == 'Error: install the required near-cli-rs as described in the README' ]]
}
@test "compound APY and projected gains use on-chain history on the first run" {
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [[ "$output" == *'Daily Gain  +0.0067 $NEAR'* ]]
    [[ "$output" == *'Annual Gain +2.60 $NEAR'* ]]
    [[ "$output" == *'APY         13.00%'* ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/near.calls")" == *'view-account-summary example.near network-config mainnet at-block-height'* ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/near.calls")" == *'get_account_total_balance'* ]]
    [ ! -e "$XDG_CACHE_HOME" ]
}
@test "unchanged balance produces zero gains and zero APY" {
    export OLD_NATIVE=12.5
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [[ "$output" == *'Daily Gain  +0.0000 $NEAR'* ]]
    [[ "$output" == *'Annual Gain +0.00 $NEAR'* ]]
    [[ "$output" == *'APY         0.00%'* ]]
}
@test "decreased balance produces negative gains and APY without a plus-minus prefix" {
    export OLD_NATIVE=13.5
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [[ "$output" == *'Daily Gain  -'* ]]
    [[ "$output" == *'Annual Gain -'* ]]
    [[ "$output" == *'APY         -'* ]]
    [[ "$output" != *'+-'* ]]
}
@test "unavailable historical account yields N/A but preserves the current balance" {
    export HISTORICAL_FAILURE=1
    run --separate-stderr bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [[ "$output" == *'20.00000000 $NEAR'* ]]
    [[ "$output" == *'Daily Gain  N/A'* ]]
    [[ "$output" == *'Annual Gain N/A'* ]]
    [[ "$output" == *'APY         N/A'* ]]
    [[ "$output" != *'N/A%'* && "$output" != *'N/A $NEAR'* ]]
}
@test "unavailable block history yields N/A without losing the report" {
    export RPC_FAILURE=1
    run --separate-stderr bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [[ "$output" == *'APY         N/A'* ]]
    [[ "$output" == *'20.00000000 $NEAR'* ]]
}
@test "unstaked funds inside pools are included without double-counting delegated stake" {
    export POOL_TOTAL_YOCTO=8500000000000000000000000
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [[ "$output" == *'22.00000000 $NEAR'* ]]
}
@test "incomplete current pool balance fails instead of reporting a false total" {
    export POOL_QUERY_FAILURE=1
    run bash "$SCRIPT" example.near
    [ "$status" -eq 1 ]
    [[ "$output" == 'Error: could not retrieve the complete current balance' ]]
}
@test "zero historical capital cannot define APY or projected gains" {
    export OLD_NATIVE=0 OLD_VALIDATOR=0 POOL_TOTAL_YOCTO=0
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [[ "$output" == *'Daily Gain  N/A'* ]]
    [[ "$output" == *'Annual Gain N/A'* ]]
    [[ "$output" == *'APY         N/A'* ]]
}
@test "zero current capital produces minus 100 percent APY and zero projected gains" {
    export CURRENT_NATIVE=0 CURRENT_VALIDATOR=0 POOL_TOTAL_YOCTO=0
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [[ "$output" == *'Daily Gain  0.0000 $NEAR'* ]]
    [[ "$output" == *'Annual Gain 0.00 $NEAR'* ]]
    [[ "$output" == *'APY         -100.00%'* ]]
}
@test "historical summary from a different block is rejected" {
    export WRONG_OLD_BLOCK=1
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [[ "$output" == *'APY         N/A'* ]]
}
@test "block search tolerates skipped heights and uses actual timestamps" {
    export SKIPPED_BLOCK=1 BLOCK_SECONDS=2
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [[ "$output" != *'APY         N/A'* ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/blocks.calls")" == *111192671* ]]
}
@test "price reporting still works when historical yield is unavailable" {
    export HISTORICAL_FAILURE=1
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [[ "$output" == *'APY         N/A'* ]]
    [[ "$output" == *'~$40 [by $2.0000'* ]]
}
@test "accounts with no staking pools use only native and validator balances" {
    export NO_POOLS=1
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [[ "$output" == *'13.50000000 $NEAR'* ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/near.calls")" != *get_account_total_balance* ]]
}
@test "non-archival mainnet RPC is configured silently only once" {
    export CONFIG_RPC=https://rpc.mainnet.fastnear.com/
    for attempt in 1 2; do
        run --separate-stderr bash "$SCRIPT" example.near
        [ "$status" -eq 0 ]
        [ -z "$stderr" ]
    done
    [ "$(grep -c 'config edit-connection' "$BATS_TEST_TMPDIR/near.calls")" -eq 1 ]
    [ "$(cat "$BATS_TEST_TMPDIR/config.rpc")" = https://archival-rpc.mainnet.fastnear.com/ ]
}
@test "existing custom archival RPC is preserved" {
    export CONFIG_RPC=https://archival-rpc.example.org/
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [[ "$(cat "$BATS_TEST_TMPDIR/near.calls")" != *'config edit-connection'* ]]
    [ ! -e "$BATS_TEST_TMPDIR/config.rpc" ]
}
@test "missing mainnet RPC uses the default archival endpoint" {
    export CONFIG_RPC=''
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/config.rpc")" = https://archival-rpc.mainnet.fastnear.com/ ]
}
@test "configuration read failure does not overwrite configuration or query accounts" {
    export CONFIG_READ_FAILURE=1
    run bash "$SCRIPT" example.near
    [ "$status" -eq 1 ]
    [ "$output" = 'Error: could not read near-cli network configuration' ]
    [[ "$(cat "$BATS_TEST_TMPDIR/near.calls")" != *'config edit-connection'* ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/near.calls")" != *'view-account-summary'* ]]
}
@test "configuration write failure stops before account queries" {
    export CONFIG_RPC=https://rpc.mainnet.fastnear.com/ CONFIG_WRITE_FAILURE=1
    run bash "$SCRIPT" example.near
    [ "$status" -eq 1 ]
    [ "$output" = 'Error: could not configure the archival mainnet RPC in near-cli' ]
    [[ "$(cat "$BATS_TEST_TMPDIR/near.calls")" != *'view-account-summary'* ]]
}
@test "redirected output keeps readable links without terminal escapes" {
    export
    run bash "$SCRIPT" example.near 240229
    [ "$status" -eq 0 ]
    [[ "$output" != *$'\033'* ]]
    [[ "$output" == *'](https://nearblocks.io/blocks/222385340)'* ]]
    [[ "$output" == *'](https://www.coinbase.com/price/near-protocol)'* ]]
}
@test "terminal output formats both links with OSC 8 and closes them" {
    export
    run env SCRIPT="$SCRIPT" script -qec 'bash "$SCRIPT" example.near 240229' /dev/null </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\033]8;;https://nearblocks.io/blocks/222385340\033\\#222385340 '* ]]
    [[ "$output" == *$'\033]8;;https://www.coinbase.com/price/near-protocol\033\\by $2.0000 close price at Feb 29, 2024 UTC on Coinbase\033]8;;\033\\'* ]]
    [[ "$output" == *$'3LbJoQaZCUskZYKfeUoDMbxEqH4pvp3rmmY4avdKvE8G\033]8;;\033\\'* ]]
}
@test "NO_COLOR disables terminal hyperlinks even when its value is empty" {
    for value in '' 1; do
        export NO_COLOR="$value"
        run env SCRIPT="$SCRIPT" script -qec 'bash "$SCRIPT" example.near 240229' /dev/null </dev/null
        [ "$status" -eq 0 ]
        [[ "$output" != *$'\033'* ]]
        [[ "$output" == *'](https://nearblocks.io/blocks/222385340)'* ]]
        [[ "$output" == *'](https://www.coinbase.com/price/near-protocol)'* ]]
    done
}


@test "only the requested candle timestamp supplies the close" {
    export TEST_TODAY=2026-10-31
    export PRICE_RESPONSE='[[1793404800,1,9,3,8,100],[1793318400,1,5,3,4.2864,100],[1793232000,1,9,3,7,100]]'
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [[ "$output" == *'~$86 [by $4.2864 close price at Oct 30, 2026 UTC on Coinbase]'* ]]
}
@test "invalid or missing candles fail without substituting a live quote" {
    for response in '{}' '[]' '<html>error</html>'         '[[1793318401,1,5,3,4,100]]'         '[[1793318400,1,5,3,4]]'         '[[1793318400,1,5,3,4,100],[1793318400,1,5,3,4,100]]'         '[[1793318400,1,5,3,"4",100]]'         '[[1793318400,1,5,3,0,100]]'         '[[1793318400,1,5,3,-1,100]]'         '[[1793318400,1,5,3,null,100]]'         '[[1793318400,1,5,3,1e999,100]]'; do
        export PRICE_RESPONSE="$response" TEST_TODAY=2026-10-31
        run bash "$SCRIPT" example.near
        [ "$status" -eq 1 ]
        [[ "$output" == 'Error: Coinbase did not return a valid NEAR USD daily close'* ]]
        [[ "$output" != *'~$'* ]]
    done
    [[ "$(cat "$BATS_TEST_TMPDIR/curl.calls")" != */ticker* ]]
}
@test "invalid current quotes never produce a valuation" {
    for response in '{}' '[]' '<html>error</html>' '{"price":null}' '{"price":0}'         '{"price":"0"}' '{"price":"-1"}' '{"price":"NaN"}' '{"price":"Infinity"}' '{"price":"abc"}'; do
        export PRICE_RESPONSE="$response"
        run bash "$SCRIPT" example.near now
        [ "$status" -eq 1 ]
        [[ "$output" == 'Error: Coinbase did not return a valid current NEAR USD price' ]]
    done
    [[ "$(cat "$BATS_TEST_TMPDIR/curl.calls")" != */candles* ]]
}
@test "HTTP and network errors fail in both price modes" {
    export PRICE_NETWORK_FAILURE=1
    for mode in now 240229; do
        run bash "$SCRIPT" example.near "$mode"
        [ "$status" -eq 1 ]
        [[ "$output" == 'Error: could not request'* ]]
        [[ "$output" != *'~$'* ]]
    done
}

@test "verified history is reused when archival account reads fail" {
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    jq -e '.network == "mainnet" and (.snapshots | length == 2)' "$HOME/.near-balance/example.near-history.json"
    : > "$BATS_TEST_TMPDIR/near.calls"
    export HISTORICAL_FAILURE=1 CURRENT_NATIVE=12.6
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [[ "$output" != *'APY         N/A'* ]]
    [[ "$output" != *'APY         13.00%'* ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/near.calls")" != *'view-account-summary example.near network-config mainnet at-block-height'* ]]
}
@test "history recovers on the fifth attempt and is cached" {
    export HISTORY_FAIL_COUNT=4
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [[ "$output" != *'APY         N/A'* ]]
    [ "$(cat "$BATS_TEST_TMPDIR/history.attempts")" -eq 5 ]
    [ "$(wc -l < "$BATS_TEST_TMPDIR/sleep.calls")" -eq 4 ]
    [ -f "$HOME/.near-balance/example.near-history.json" ]
}
@test "history stops after five failed attempts" {
    export HISTORY_FAIL_COUNT=5
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [[ "$output" == *'APY         N/A'* ]]
    [ "$(cat "$BATS_TEST_TMPDIR/history.attempts")" -eq 5 ]
    [ "$(wc -l < "$BATS_TEST_TMPDIR/sleep.calls")" -eq 4 ]
}
@test "invalid foreign and expired cache records are fetched again" {
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    cp "$HOME/.near-balance/example.near-history.json" "$BATS_TEST_TMPDIR/valid.json"
    for mutation in '.account="other.near"' '.network="testnet"' '.snapshots[].timestamp=1' '.snapshots[].balance="-1"'; do
        jq "$mutation" "$BATS_TEST_TMPDIR/valid.json" > "$HOME/.near-balance/example.near-history.json"
        : > "$BATS_TEST_TMPDIR/near.calls"
        run bash "$SCRIPT" example.near
        [ "$status" -eq 0 ]
        [[ "$output" != *'APY         N/A'* ]]
        [[ "$(cat "$BATS_TEST_TMPDIR/near.calls")" == *'view-account-summary example.near network-config mainnet at-block-height'* ]]
    done
}
@test "unwritable cache does not prevent a fresh calculation" {
    mkdir -p "$HOME"
    touch "$HOME/.near-balance"
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [[ "$output" != *'APY         N/A'* ]]
}

seed_flow_history() {
    mkdir -p "$HOME/.near-balance"
    printf '%s\n' '{"version":1,"account":"example.near","network":"mainnet","snapshots":[{"height":219793340,"timestamp":1790808000,"hash":"3LbJoQaZCUskZYKfeUoDMbxEqH4pvp3rmmY4avdKvE8G","balance":"20.00000000"}]}' > "$HOME/.near-balance/example.near-history.json"
}
flow_response() {
    jq -cn --argjson amount "$1" --arg from "$2" --arg to "$3" '
        {cursor:null,txns:[{
            receipt_id:"receipt-one",predecessor_account_id:$from,receiver_account_id:$to,
            receipt_block:{block_height:222000000,block_timestamp:1792104000000000000},
            receipt_outcome:{status:true},actions:[{action:"TRANSFER",deposit:($amount*1e24)}]
        }]}'
}
@test "external withdrawals do not create negative APY" {
    export CURRENT_NATIVE=2.5 OLD_NATIVE=12.5
    FLOW_RESPONSE=$(flow_response 10 example.near recipient.near)
    export FLOW_RESPONSE
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [[ "$output" == *'APY         0.00%'* ]]
    [[ "$output" == *'Daily Gain  +0.0000 $NEAR'* ]]
    [[ "$output" == *'Annual Gain +0.00 $NEAR'* ]]
}
@test "external deposits do not create positive APY" {
    export CURRENT_NATIVE=22.5 OLD_NATIVE=12.5
    FLOW_RESPONSE=$(flow_response 10 sender.near example.near)
    export FLOW_RESPONSE
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [[ "$output" == *'APY         0.00%'* ]]
}
@test "cash flow timing weights capital in the return estimate" {
    seed_flow_history
    export CURRENT_NATIVE=3.5
    FLOW_RESPONSE=$(flow_response 10 example.near recipient.near)
    export FLOW_RESPONSE
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [[ "$output" == *'Daily Gain  +0.0237 $NEAR'* ]]
    [[ "$output" == *'Annual Gain +13.12 $NEAR'* ]]
    [[ "$output" == *'APY         119.29%'* ]]
}
@test "internal pool transfers self transfers and gas refunds are not external flows" {
    export OLD_NATIVE=12.5
    for pair in 'pool.near example.near' 'example.near pool.near' 'system example.near' 'example.near example.near'; do
        read -r from to <<< "$pair"
        FLOW_RESPONSE=$(flow_response 200 "$from" "$to")
        export FLOW_RESPONSE
        run bash "$SCRIPT" example.near
        [ "$status" -eq 0 ]
        [[ "$output" == *'APY         0.00%'* ]]
    done
}
@test "unavailable or malformed flow history cannot produce APY" {
    for response in '{}' '<html>error</html>' '{"cursor":"123","txns":[]}' '{"cursor":null,"txns":[{}]}'; do
        export FLOW_RESPONSE="$response"
        run bash "$SCRIPT" example.near
        [ "$status" -eq 0 ]
        [[ "$output" == *'Daily Gain  N/A'* ]]
        [[ "$output" == *'Annual Gain N/A'* ]]
        [[ "$output" == *'APY         N/A'* ]]
    done
    export FLOW_FAILURE=1
    run bash "$SCRIPT" example.near
    [[ "$output" == *'APY         N/A'* ]]
}
@test "flow pagination removes overlapping receipts and stops on a complete history" {
    export CURRENT_NATIVE=2.5 OLD_NATIVE=12.5
    FLOW_RESPONSE=$(flow_response 10 example.near recipient.near | jq '.cursor="123"')
    FLOW_SECOND=$(flow_response 10 example.near recipient.near)
    export FLOW_RESPONSE FLOW_SECOND
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [[ "$output" == *'APY         0.00%'* ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/flows.calls")" == *cursor=123* ]]
}
@test "repeated flow cursors fail closed" {
    FLOW_RESPONSE=$(flow_response 10 example.near recipient.near | jq '.cursor="123"')
    export FLOW_RESPONSE FLOW_SECOND="$FLOW_RESPONSE"
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [[ "$output" == *'APY         N/A'* ]]
}

@test "failed and out of interval receipts cannot affect return" {
    seed_flow_history
    export OLD_NATIVE=12.5
    for change in '.txns[0].receipt_outcome.status=false' '.txns[0].receipt_block.block_height=219793340' '.txns[0].receipt_block.block_height=222385341'; do
        FLOW_RESPONSE=$(flow_response 10 example.near recipient.near | jq "$change")
        export FLOW_RESPONSE
        run bash "$SCRIPT" example.near
        [ "$status" -eq 0 ]
        [[ "$output" == *'APY         0.00%'* ]]
    done
}
@test "attached deposits are external flows and malformed monetary amounts fail closed" {
    seed_flow_history
    export CURRENT_NATIVE=2.5
    FLOW_RESPONSE=$(flow_response 10 example.near app.near | jq '.txns[0].actions[0].action="FUNCTION_CALL"')
    export FLOW_RESPONSE
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [[ "$output" == *'APY         0.00%'* ]]
    for change in '.txns[0].actions[0].deposit=null' '.txns[0].actions[0].deposit=-1' '.txns[0].actions[0].action="DELETE_ACCOUNT"' '.cursor=false' '.cursor=123' '.cursor=""'; do
        FLOW_RESPONSE=$(flow_response 10 example.near app.near | jq "$change")
        export FLOW_RESPONSE
        run bash "$SCRIPT" example.near
        [ "$status" -eq 0 ]
        [[ "$output" == *'APY         N/A'* ]]
    done
}
@test "nonpositive weighted capital or negative growth factor yields N/A" {
    seed_flow_history
    export CURRENT_NATIVE=0 CURRENT_VALIDATOR=0 POOL_TOTAL_YOCTO=0
    FLOW_RESPONSE=$(flow_response 40 example.near recipient.near)
    export FLOW_RESPONSE
    run bash "$SCRIPT" example.near
    [[ "$output" == *'APY         N/A'* ]]
    FLOW_RESPONSE=$(flow_response 100 sender.near example.near)
    export FLOW_RESPONSE
    run bash "$SCRIPT" example.near
    [[ "$output" == *'APY         N/A'* ]]
}
@test "pure withdrawal of all funds preserves zero return" {
    seed_flow_history
    export CURRENT_NATIVE=0 CURRENT_VALIDATOR=0 POOL_TOTAL_YOCTO=0
    FLOW_RESPONSE=$(flow_response 20 example.near recipient.near)
    export FLOW_RESPONSE
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [[ "$output" == *'APY         0.00%'* ]]
    [[ "$output" == *'Daily Gain  +0.0000 $NEAR'* ]]
}

@test "missing required dependencies fail before account reads" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    ln -s "$BATS_FILE_TMPDIR/helpers/near" "$BATS_TEST_TMPDIR/bin/near"
    for dependency in curl jq timeout; do
        run env PATH="$BATS_TEST_TMPDIR/bin" /bin/bash "$SCRIPT" example.near now
        [ "$status" -eq 1 ]
        [[ "$output" == "Error: $dependency is required" ]]
        [ ! -e "$BATS_TEST_TMPDIR/near.calls" ]
        ln -s /bin/true "$BATS_TEST_TMPDIR/bin/$dependency"
    done
}
@test "invalid current block fails before staking or price queries" {
    export CURRENT_BLOCK=invalid
    run bash "$SCRIPT" example.near now
    [ "$status" -eq 1 ]
    [[ "$output" == 'Error: could not read the account block' ]]
    [ ! -e "$BATS_TEST_TMPDIR/flows.calls" ]
    [ ! -e "$BATS_TEST_TMPDIR/curl.calls" ]
}

@test "terminal receipt pages accept an omitted or null cursor" {
    seed_flow_history
    export CURRENT_NATIVE=2.5
    for change in 'del(.cursor)' '.cursor=null'; do
        FLOW_RESPONSE=$(flow_response 10 example.near recipient.near | jq "$change")
        export FLOW_RESPONSE
        run bash "$SCRIPT" example.near
        [ "$status" -eq 0 ]
        [[ "$output" == *'APY         0.00%'* ]]
    done
    export CURRENT_NATIVE=12.5 FLOW_RESPONSE='{"txns":[]}'
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [[ "$output" == *'APY         0.00%'* ]]
}

@test "receipt history tolerates execution heights outside transaction order" {
    seed_flow_history
    export CURRENT_NATIVE=2.5
    FLOW_RESPONSE=$(flow_response 10 example.near recipient.near | jq '
        del(.cursor) | .txns = [(.txns[0] | .receipt_id="old" | .receipt_block.block_height=219793340), .txns[0]]')
    export FLOW_RESPONSE
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [[ "$output" == *'APY         0.00%'* ]]
    calls=$(cat "$BATS_TEST_TMPDIR/flows.calls")
    [[ "$calls" == *'/account/example.near/receipts'* ]]
    [[ "$calls" == *'after_date=2026-09-29'* ]]
    [[ "$calls" == *'before_date=2026-10-31'* ]]
}

@test "an old receipt cannot stop pagination before a delayed in range receipt" {
    seed_flow_history
    export CURRENT_NATIVE=2.5
    FLOW_RESPONSE=$(flow_response 200 example.near recipient.near | jq '
        .cursor="123" | .txns[0].receipt_id="old" | .txns[0].receipt_block.block_height=219793340')
    FLOW_SECOND=$(flow_response 10 example.near recipient.near | jq 'del(.cursor)')
    export FLOW_RESPONSE FLOW_SECOND
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [[ "$output" == *'APY         0.00%'* ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/flows.calls")" == *cursor=123* ]]
}
