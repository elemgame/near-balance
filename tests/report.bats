#!/usr/bin/env bats
setup() {
    bats_require_minimum_version 1.5.0
    export PATH="$BATS_TEST_DIRNAME/helpers:$PATH"
    export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
    unset COINMARKETCAP_API_KEY HISTORY_RESPONSE
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
    [[ "$output" == *'APY                 5.09%' ]]
    [[ "$output" != *'Error'* && "$output" != *'Warning'* ]]
    [ ! -e "$BATS_TEST_TMPDIR/curl.calls" ]
    [ -s "$XDG_CACHE_HOME/near-balance/example.near.state" ]
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
    [[ "$output" == 'Error: near-cli-rs is required;'* ]]
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
    [[ "$output" == 'Error: invalid CoinMarketCap API key.' ]]
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
