#!/usr/bin/env bats
setup() {
    bats_require_minimum_version 1.5.0
    export PATH="$BATS_TEST_DIRNAME/helpers:$PATH"
    export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
    unset COINMARKETCAP_API_KEY HISTORY_RESPONSE HISTORICAL_FAILURE RPC_FAILURE
    unset CURRENT_NATIVE OLD_NATIVE POOL_TOTAL_YOCTO POOL_QUERY_FAILURE POOL_DISCOVERY_FAILURE
    unset CURRENT_VALIDATOR OLD_VALIDATOR WRONG_OLD_BLOCK SKIPPED_BLOCK BLOCK_SECONDS NO_POOLS
    unset CONFIG_RPC CONFIG_READ_FAILURE CONFIG_WRITE_FAILURE NEAR_BALANCE_RPC_URL
    SCRIPT="$BATS_TEST_DIRNAME/../near-balance.sh"
}
@test "missing account prints usage" {
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == Usage:* ]]
}
@test "unset API key quietly omits price and makes no price requests" {
    run --separate-stderr bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [ -z "${stderr:-}" ]
    [[ "$output" == *'20.00000000 $NEAR'* ]]
    [[ "$output" != *'APY         N/A'* ]]
    [[ "$output" != *'Error'* && "$output" != *'Warning'* ]]
    [ ! -e "$BATS_TEST_TMPDIR/curl.calls" ]
    [ ! -e "$XDG_CACHE_HOME/near-balance/example.near.state" ]
}
@test "empty API key also omits price" {
    export COINMARKETCAP_API_KEY=''
    run --separate-stderr bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [ -z "${stderr:-}" ]
    [[ "$output" != *'~$'* ]]
    [ ! -e "$BATS_TEST_TMPDIR/curl.calls" ]
}
@test "API key enables historical price and requested date" {
    export COINMARKETCAP_API_KEY=test-key
    run bash "$SCRIPT" example.near 261011
    [ "$status" -eq 0 ]
    [[ "$output" == *'~$40 [by $2.0000 close price at Oct 11]'* ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/curl.calls")" == *'2026-10-11T00:00:00Z'* ]]
}
@test "unavailable historical price falls back to latest" {
    export COINMARKETCAP_API_KEY=test-key HISTORY_RESPONSE='{}'
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [[ "$output" == *'~$60 [by $3.0000'* ]]
}
@test "missing near fails without attempting package installation" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    ln -s "$(command -v mkdir)" "$BATS_TEST_TMPDIR/bin/mkdir"
    ln -s "$BATS_TEST_DIRNAME/helpers/npm" "$BATS_TEST_TMPDIR/bin/npm"
    run env PATH="$BATS_TEST_TMPDIR/bin" /bin/bash "$SCRIPT" example.near
    [ "$status" -eq 1 ]
    [[ "$output" == 'Error: install the required near-cli-rs as described in the README' ]]
}
@test "API key stays out of request arguments and report output" {
    export COINMARKETCAP_API_KEY=test-key HISTORY_RESPONSE='{}'
    run bash "$SCRIPT" example.near
    [ "$status" -eq 0 ]
    [[ "$output" != *test-key* ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/curl.calls")" != *test-key* ]]
    [ "$(wc -l < "$BATS_TEST_TMPDIR/curl.calls")" -eq 2 ]
}
@test "API key cannot inject extra headers" {
    export COINMARKETCAP_API_KEY=$'test-key\nInjected: header'
    run bash "$SCRIPT" example.near
    [ "$status" -eq 1 ]
    [[ "$output" == 'Error: invalid CoinMarketCap API key' ]]
    [ ! -e "$BATS_TEST_TMPDIR/curl.calls" ]
}
@test "explicit valid date without a key warns and still reports balance" {
    for key_state in unset empty; do
        unset COINMARKETCAP_API_KEY
        if [[ "$key_state" == empty ]]; then
            export COINMARKETCAP_API_KEY=''
        fi
        run --separate-stderr bash "$SCRIPT" example.near 240229
        [ "$status" -eq 0 ]
        [ "$stderr" = 'Warning: set COINMARKETCAP_API_KEY to display the price for the requested date' ]
        [[ "$output" == *'20.00000000 $NEAR'* ]]
        [[ "$output" != *'~$'* ]]
        [ ! -e "$BATS_TEST_TMPDIR/curl.calls" ]
    done
}
@test "invalid date formats and impossible dates fail before creating state" {
    for key in '' test-key; do
        export COINMARKETCAP_API_KEY="$key"
        for price_date in '' 26101 2610111 26aa11 2026-10-11 260229 261332 260431; do
            run --separate-stderr bash "$SCRIPT" example.near "$price_date"
            [ "$status" -eq 1 ]
            [[ "$stderr" == *'Error: price date'* ]]
            [ -z "$output" ]
            [ ! -e "$XDG_CACHE_HOME" ]
            [ ! -e "$BATS_TEST_TMPDIR/curl.calls" ]
        done
    done
}
@test "today and future dates have no closing price even without a key" {
    for key in '' test-key; do
        export COINMARKETCAP_API_KEY="$key"
        for price_date in "$(date -u +%y%m%d)" "$(date -u -d tomorrow +%y%m%d)"; do
            run --separate-stderr bash "$SCRIPT" example.near "$price_date"
            [ "$status" -eq 1 ]
            [[ "$stderr" == *'Error: price date must be before today (UTC)'* ]]
            [ -z "$output" ]
            [ ! -e "$XDG_CACHE_HOME" ]
        done
    done
}
@test "valid leap day with a key requests its historical price without warning" {
    export COINMARKETCAP_API_KEY=test-key
    run --separate-stderr bash "$SCRIPT" example.near 240229
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [[ "$(cat "$BATS_TEST_TMPDIR/curl.calls")" == *'2024-02-29T00:00:00Z'* ]]
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
    export HISTORICAL_FAILURE=1 COINMARKETCAP_API_KEY=test-key
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
