#!/usr/bin/env bash
set -euo pipefail

# Keep the optional credential out of child-process environments
cmc_api_key="${COINMARKETCAP_API_KEY:-}"
export -n cmc_api_key
unset COINMARKETCAP_API_KEY

# Configuration and argument validation
ACCOUNT="${1:-}"
PRICE_DATE_ARG="${2:-}" # Optional: YYMMDD (for example, 261011)

if [[ -z "$ACCOUNT" ]]; then
    echo "Usage: $0 <account.near> [YYMMDD]" >&2
    exit 1
fi

# Validate explicit dates even when pricing is disabled
if (( $# >= 2 )); then
    if [[ -z "$cmc_api_key" ]]; then
        echo "Warning: set COINMARKETCAP_API_KEY to display the price for the requested date" >&2
    fi

    if [[ ! "$PRICE_DATE_ARG" =~ ^[0-9]{6}$ ]]; then
        echo "Error: price date must use YYMMDD format" >&2
        exit 1
    fi

    TARGET_ISO="20${PRICE_DATE_ARG:0:2}-${PRICE_DATE_ARG:2:2}-${PRICE_DATE_ARG:4:2}"
    if ! VALIDATED_DATE=$(LC_ALL=C date -u -d "$TARGET_ISO" +%Y-%m-%d 2>/dev/null) ||
        [[ "$VALIDATED_DATE" != "$TARGET_ISO" ]]; then
        echo "Error: price date is not a valid calendar date" >&2
        exit 1
    fi

    TODAY_ISO=$(LC_ALL=C date -u +%Y-%m-%d)
    if [[ ! "$TARGET_ISO" < "$TODAY_ISO" ]]; then
        echo "Error: price date must be before today (UTC) to have a closing price" >&2
        exit 1
    fi
fi

# 1 Resolve the separately installed near-cli-rs executable
if ! NEAR_BIN=$(type -P near); then
    echo "Error: install the required near-cli-rs as described in the README" >&2
    exit 1
fi

# Read-only helpers for complete balances and historical block discovery
clean_summary() {
    sed -E $'s/\x1b\\[[0-9;]*[a-zA-Z]//g; s/\r//g; s/\xc2\xa0/ /g'
}

# Sum native and validator balances before adding pool totals
base_balance() {
    awk '
        /Native account balance|Validator stake/ {
            for (i = 2; i <= NF; i++) {
                if ($i == "NEAR" && $(i-1) ~ /^[0-9]+([.][0-9]+)?$/) {
                    sum += $(i-1)
                    if ($0 ~ /Native account balance/) native = 1
                }
            }
        }
        END { if (!native) exit 1; printf "%.18f\n", sum }
    '
}

# Query every historically used pool, including pools with only unstaked funds
complete_balance() {
    local summary="$1" height="$2" total pool amount
    total=$(printf '%s\n' "$summary" | base_balance) || return 1
    while IFS= read -r pool; do
        [[ -n "$pool" ]] || continue
        amount=$("$NEAR_BIN" --quiet contract call-function as-read-only "$pool" \
            get_account_total_balance json-args "$ACCOUNT_ARGS" \
            network-config mainnet at-block-height "$height" 2>/dev/null) || return 1
        amount=$(printf '%s' "$amount" | jq -er 'select(type == "string" and test("^[0-9]+$"))') || return 1
        total=$(awk -v total="$total" -v amount="$amount" 'BEGIN {printf "%.18f", total + amount / 1e24}') || return 1
    done <<< "$POOLS"
    awk -v total="$total" 'BEGIN {printf "%.8f\n", total}'
}

# Return an existing block's height, UTC timestamp in seconds, and hash
block_info() {
    local height="$1" response
    response=$(curl -fsS --connect-timeout 5 --max-time 20 \
        "$BALANCE_RPC_URL" -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"id\":\"balance\",\"method\":\"block\",\"params\":{\"block_id\":$height}}") || return 1
    printf '%s' "$response" | jq -er '
        .result.header |
        select(.height | type == "number") |
        [.height, (((.timestamp_nanosec // .timestamp) | tonumber) / 1000000000 | floor), .hash] |
        @tsv'
}

# Search timestamps rather than assuming a fixed block production rate
historical_block() {
    local target="$1" high="$2" low=0 mid probe info height timestamp _hash attempt
    for ((attempt=0; attempt<40 && low<=high; attempt++)); do
        mid=$((low + (high - low) / 2))
        info=''
        # Try nearby heights when a block height is skipped
        for ((probe=mid; probe<=mid+8 && probe<=high; probe++)); do
            if info=$(block_info "$probe" 2>/dev/null) && [[ -n "$info" ]]; then
                break
            fi
        done
        [[ -n "$info" ]] || return 1
        read -r height timestamp _hash <<< "$info"
        [[ "$height" =~ ^[0-9]+$ && "$timestamp" =~ ^[0-9]+$ ]] || return 1
        (( height >= low && height <= high )) || return 1
        if (( timestamp <= target && target - timestamp <= 3600 )); then
            printf '%s\n' "$info"
            return 0
        elif (( timestamp > target )); then
            high=$((mid - 1))
        else
            low=$((height + 1))
        fi
    done
    return 1
}

# 2 Query a current summary, then pin all pool queries to the same block
for dependency in curl jq; do
    if ! command -v "$dependency" >/dev/null; then
        echo "Error: $dependency is required" >&2
        exit 1
    fi
done
# Configure historical reads once while preserving an existing archival mainnet RPC
DEFAULT_ARCHIVAL_RPC='https://archival-rpc.mainnet.fastnear.com/'
if ! NEAR_CONFIG=$("$NEAR_BIN" --quiet config show-connections 2>&1); then
    echo 'Error: could not read near-cli network configuration' >&2
    exit 1
fi
CURRENT_MAINNET_RPC=$(printf '%s\n' "$NEAR_CONFIG" | clean_summary | awk '
    /^\[network_connection\.mainnet\]$/ { mainnet = 1; next }
    /^\[/ { mainnet = 0 }
    mainnet && /^rpc_url[[:space:]]*=/ { split($0, parts, "\""); print parts[2]; exit }
')
unset NEAR_CONFIG
if [[ "$CURRENT_MAINNET_RPC" != *archival-rpc* ]]; then
    if ! "$NEAR_BIN" --quiet config edit-connection mainnet --key rpc_url \
        --value "$DEFAULT_ARCHIVAL_RPC" >/dev/null 2>&1; then
        echo 'Error: could not configure the archival mainnet RPC in near-cli' >&2
        exit 1
    fi
fi
BALANCE_RPC_URL="${NEAR_BALANCE_RPC_URL:-$DEFAULT_ARCHIVAL_RPC}"
RAW_OUTPUT=$("$NEAR_BIN" account view-account-summary "$ACCOUNT" network-config mainnet now 2>&1)
CLEAN_OUTPUT=$(printf '%s\n' "$RAW_OUTPUT" | clean_summary)
BLOCK_NUM=$(printf '%s\n' "$CLEAN_OUTPUT" | awk '/At block #[0-9]+/ {for(i=1;i<=NF;i++) if($i ~ /^#[0-9]+/) {sub("#","",$i); print $i; exit}}')
BLOCK_HASH=$(printf '%s\n' "$CLEAN_OUTPUT" | awk -F'[()]' '/\([1-9A-HJ-NP-Za-km-z]{32,48}\)/ {print $2; exit}')
if [[ ! "$BLOCK_NUM" =~ ^[0-9]+$ ]]; then
    echo 'Error: could not read the account block' >&2
    exit 1
fi
ACCOUNT_ARGS=$(jq -cn --arg account "$ACCOUNT" '{account_id: $account}')
# Encode the account as a URL path segment, not as part of the URL syntax
ACCOUNT_PATH=$(jq -rn --arg account "$ACCOUNT" '$account | @uri')
POOL_RESPONSE=$(curl -fsS --connect-timeout 5 --max-time 20 "https://api.fastnear.com/v1/account/$ACCOUNT_PATH/staking")
if ! POOLS=$(printf '%s' "$POOL_RESPONSE" | jq -er --arg account "$ACCOUNT" '
    select(.account_id == $account and (.pools | type == "array")) |
    [.pools[].pool_id] |
    select(all(.[]; type == "string" and test("^[a-z0-9]+([._-][a-z0-9]+)*$"))) |
    unique | join("\n")'); then
    echo 'Error: could not discover the account staking pools' >&2
    exit 1
fi
if ! TOTAL_NEAR=$(complete_balance "$CLEAN_OUTPUT" "$BLOCK_NUM"); then
    echo 'Error: could not retrieve the complete current balance' >&2
    exit 1
fi

# 3 Estimate compound growth from total balances approximately 30 days apart
DAILY_GAIN='N/A'
ANNUAL_GAIN='N/A'
APY='N/A'
NOW_EPOCH=$(date -u +%s)
if CURRENT_INFO=$(block_info "$BLOCK_NUM" 2>/dev/null) && [[ -n "$CURRENT_INFO" ]]; then
    read -r CURRENT_HEIGHT CURRENT_TS CURRENT_HASH <<< "$CURRENT_INFO"
    if [[ "$CURRENT_HEIGHT" == "$BLOCK_NUM" && "$CURRENT_HASH" == "$BLOCK_HASH" && "$CURRENT_TS" =~ ^[0-9]+$ ]]; then
        NOW_EPOCH="$CURRENT_TS"
        if OLD_INFO=$(historical_block "$((CURRENT_TS - 30 * 86400))" "$BLOCK_NUM"); then
            read -r OLD_HEIGHT OLD_TS OLD_HASH <<< "$OLD_INFO"
            if OLD_RAW=$("$NEAR_BIN" account view-account-summary "$ACCOUNT" network-config mainnet at-block-height "$OLD_HEIGHT" 2>&1) &&
                OLD_CLEAN=$(printf '%s\n' "$OLD_RAW" | clean_summary) &&
                [[ "$OLD_CLEAN" == *"At block #$OLD_HEIGHT"* && "$OLD_CLEAN" == *"($OLD_HASH)"* ]] &&
                OLD_TOTAL=$(complete_balance "$OLD_CLEAN" "$OLD_HEIGHT" 2>/dev/null); then
                ELAPSED=$((CURRENT_TS - OLD_TS))
                if GROWTH=$(awk -v current="$TOTAL_NEAR" -v previous="$OLD_TOTAL" -v dt="$ELAPSED" '
                    BEGIN {
                        if (previous <= 0 || current < 0 || dt < 30*86400 || dt > 31*86400) exit 1
                        if (current == 0) { print "0.0000 0.00 -100.00"; exit }
                        rate = log(current / previous) / dt
                        if (rate * 365 * 86400 > 600) exit 1
                        daily = current * (exp(rate * 86400) - 1)
                        annual_rate = exp(rate * 365 * 86400) - 1
                        printf "%+.4f %+.2f %.2f\n", daily, current * annual_rate, 100 * annual_rate
                    }'); then
                    read -r DAILY_GAIN ANNUAL_GAIN APY <<< "$GROWTH"
                    DAILY_GAIN="$DAILY_GAIN \$NEAR"
                    ANNUAL_GAIN="$ANNUAL_GAIN \$NEAR"
                    APY="$APY%"
                fi
            fi
        fi
    fi
fi
NOW_STR=$(LC_ALL=C date -u -d "@$NOW_EPOCH" '+%b %d, %Y %H:%M:%S UTC')

# 4 Fetch the NEAR closing price from the CoinMarketCap API
if [[ -n "${cmc_api_key:-}" ]]; then
    if [[ -z "$PRICE_DATE_ARG" ]]; then
        TARGET_ISO=$(LC_ALL=C date -u -d "yesterday" "+%Y-%m-%d")
    fi

    TARGET_LABEL=$(LC_ALL=C date -u -d "$TARGET_ISO" "+%b %d")
    TIME_START="${TARGET_ISO}T00:00:00Z"
    TIME_END="${TARGET_ISO}T23:59:59Z"

    # Read the header from stdin so the key never appears in curl arguments
    if [[ "$cmc_api_key" == *$'\r'* || "$cmc_api_key" == *$'\n'* ]]; then
        echo "Error: invalid CoinMarketCap API key" >&2
        exit 1
    fi

    # Try historical OHLCV first (requires a paid CMC plan)
    CMC_HIST=$(curl -sS -G "https://pro-api.coinmarketcap.com/v2/cryptocurrency/ohlcv/historical" \
        -H @- \
        --data-urlencode "symbol=NEAR" \
        --data-urlencode "time_start=${TIME_START}" \
        --data-urlencode "time_end=${TIME_END}" \
        --data-urlencode "convert=USD" <<< "X-CMC_PRO_API_KEY: $cmc_api_key" || true)

    CLOSE_PRICE=$(printf "%s" "$CMC_HIST" | jq -r '
        (.. | objects | select(has("close")) | .close) // empty
    ' 2>/dev/null | head -n 1)

    # Fall back to quotes/latest for the free CMC Basic plan
    if [[ -z "$CLOSE_PRICE" || "$CLOSE_PRICE" == "null" ]]; then
        CMC_LATEST=$(curl -sS -G "https://pro-api.coinmarketcap.com/v2/cryptocurrency/quotes/latest" \
            -H @- \
            --data-urlencode "symbol=NEAR" \
            --data-urlencode "convert=USD" <<< "X-CMC_PRO_API_KEY: $cmc_api_key")

        CLOSE_PRICE=$(printf "%s" "$CMC_LATEST" | jq -r '
            .data.NEAR[0].quote.USD.price // .data.NEAR.quote.USD.price // empty
        ')
    fi

    if [[ -z "$CLOSE_PRICE" || "$CLOSE_PRICE" == "null" ]]; then
        echo "Error: could not retrieve the NEAR price from CoinMarketCap API" >&2
        exit 1
    fi

    PRICE_FMT=$(awk -v p="$CLOSE_PRICE" 'BEGIN { printf "%.4f", p }')
    USD_TOTAL=$(awk -v b="$TOTAL_NEAR" -v p="$CLOSE_PRICE" 'BEGIN { printf "%.0f", b * p }')

fi

# 5 Format the final report
cat <<EOF
${NOW_STR} At block [#${BLOCK_NUM} ${BLOCK_HASH}] (https://nearblocks.io/blocks/${BLOCK_NUM})

${TOTAL_NEAR} \$NEAR ${NOW_STR}

Daily Gain  ${DAILY_GAIN}
Annual Gain ${ANNUAL_GAIN}
APY         ${APY}
EOF
if [[ -n "${cmc_api_key:-}" ]]; then
cat <<EOF

~\$${USD_TOTAL} [by \$${PRICE_FMT} close price at ${TARGET_LABEL}](https://coinmarketcap.com/currencies/near-protocol/historical-data/)
EOF
fi
