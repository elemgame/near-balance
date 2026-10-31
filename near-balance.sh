#!/usr/bin/env bash
set -euo pipefail

# Select link formatting before command substitutions redirect stdout
if [[ -t 1 && -z "${NO_COLOR+x}" ]]; then
    format() {
        local url="$1"
        shift
        printf '\033]8;;%s\033\\%s\033]8;;\033\\\n' "$url" "$*"
    }
else
    format() {
        local url="$1"
        shift
        printf '[%s](%s)\n' "$*" "$url"
    }
fi

# Configuration and argument validation
ACCOUNT="${1:-}"
PRICE_DATE_ARG="${2:-}" # Optional: now or YYMMDD

if [[ -z "$ACCOUNT" || $# -gt 2 ]]; then
    echo "Usage: $0 <account.near> [now|YYMMDD]" >&2
    exit 1
fi

# Only completed UTC days have closing prices
if (( $# >= 2 )) && [[ "$PRICE_DATE_ARG" != now ]]; then
    if [[ ! "$PRICE_DATE_ARG" =~ ^[0-9]{6}$ ]]; then
        echo "Error: price date must be now or use YYMMDD format" >&2
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

# Retry failed or invalid reads five times with a two second pause
retry_read() {
    local attempt result
    for ((attempt=1; attempt<=5; attempt++)); do
        if result=$("$@" 2>/dev/null); then
            printf '%s\n' "$result"
            return 0
        fi
        if (( attempt < 5 )); then sleep 2; fi
    done
    return 1
}

# Accept cache records only for this account and network
read_history() {
    jq -e --arg account "$ACCOUNT" '
        select(.version == 1 and .network == "mainnet" and .account == $account) |
        .snapshots | select(type == "array") |
        select(all(.[];
            (.height | type == "number" and . > 0 and floor == .) and
            (.timestamp | type == "number" and . > 0 and floor == .) and
            (.hash | type == "string" and test("^[1-9A-HJ-NP-Za-km-z]{32,48}$")) and
            (.balance | type == "string" and test("^[0-9]+([.][0-9]+)?$")) and
            (.balance | tonumber | isfinite and . >= 0)))' "$HISTORY_FILE" 2>/dev/null
}

# Atomically preserve recent verified snapshots without making cache writes mandatory
save_history() (
    umask 077
    local snapshots temporary
    mkdir -p "$HISTORY_DIR" || return 1
    snapshots=$(read_history) || snapshots='[]'
    temporary=$(mktemp "$HISTORY_DIR/.history-XXXXXX") || return 1
    trap 'rm -f "$temporary"' EXIT
    jq -n --arg account "$ACCOUNT" --argjson snapshots "$snapshots" \
        --argjson height "$1" --argjson timestamp "$2" --arg hash "$3" --arg balance "$4" '
        {version:1, network:"mainnet", account:$account,
         snapshots: (($snapshots + [{height:$height,timestamp:$timestamp,hash:$hash,balance:$balance}]) |
            unique_by(.height) | sort_by(.timestamp) |
            . as $all | map(select(.timestamp >= ($all[-1].timestamp - 31*86400))) | if length > 64 then [.[0]] + .[-63:] else . end)}
    ' > "$temporary" || return 1
    mv -f "$temporary" "$HISTORY_FILE"
)

# Fetch and validate one historical snapshot before allowing it into the cache
fetch_history() {
    local info height timestamp hash raw clean total
    info=$(historical_block "$((CURRENT_TS - 30 * 86400))" "$BLOCK_NUM") || return 1
    read -r height timestamp hash <<< "$info"
    raw=$(timeout 20 "$NEAR_BIN" account view-account-summary "$ACCOUNT" network-config mainnet at-block-height "$height" 2>&1) || return 1
    clean=$(printf '%s\n' "$raw" | clean_summary) || return 1
    [[ "$clean" == *"At block #$height"* && "$clean" == *"($hash)"* ]] || return 1
    total=$(complete_balance "$clean" "$height") || return 1
    printf '%s\t%s\t%s\t%s\n' "$height" "$timestamp" "$hash" "$total"
}

# Verify the current block before using its timestamp for cache selection
current_block() {
    local info height timestamp hash
    info=$(block_info "$BLOCK_NUM") || return 1
    read -r height timestamp hash <<< "$info"
    [[ "$height" == "$BLOCK_NUM" && "$hash" == "$BLOCK_HASH" && "$timestamp" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$info"
}

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
        amount=$(timeout 20 "$NEAR_BIN" --quiet contract call-function as-read-only "$pool" \
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
for dependency in curl jq timeout; do
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
HISTORY_DIR="$HOME/.near-balance"
# Encode the account to prevent cache paths from escaping the cache directory
HISTORY_FILE="$HISTORY_DIR/$(jq -rn --arg account "$ACCOUNT" '$account | @uri')-history.json"
if CURRENT_INFO=$(retry_read current_block); then
    read -r CURRENT_HEIGHT CURRENT_TS CURRENT_HASH <<< "$CURRENT_INFO"
    NOW_EPOCH="$CURRENT_TS"
    OLD_INFO=$(read_history | jq -er --argjson now "$CURRENT_TS" '
        map(select(.timestamp <= $now - 30*86400 and .timestamp >= $now - 31*86400)) |
        max_by(.timestamp) | select(. != null) |
        [.height,.timestamp,.hash,.balance] | @tsv') || OLD_INFO=''
    if [[ -z "$OLD_INFO" ]]; then
        OLD_INFO=$(retry_read fetch_history) || OLD_INFO=''
    fi
    if [[ -n "$OLD_INFO" ]]; then
        read -r OLD_HEIGHT OLD_TS OLD_HASH OLD_TOTAL <<< "$OLD_INFO"
        save_history "$OLD_HEIGHT" "$OLD_TS" "$OLD_HASH" "$OLD_TOTAL" 2>/dev/null || true
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
    save_history "$CURRENT_HEIGHT" "$CURRENT_TS" "$CURRENT_HASH" "$TOTAL_NEAR" 2>/dev/null || true
fi
NOW_STR=$(LC_ALL=C date -u -d "@$NOW_EPOCH" '+%b %d, %Y %H:%M:%S UTC')

# 4 Fetch the public Coinbase NEAR USD ticker or completed daily candle
PRICE_API='https://api.exchange.coinbase.com/products/NEAR-USD'
if [[ "$PRICE_DATE_ARG" == now ]]; then
    PRICE_LABEL='current price'
    if ! PRICE_RESPONSE=$(curl -fsS --connect-timeout 5 --max-time 20 "$PRICE_API/ticker"); then
        echo 'Error: could not request the current NEAR USD price from Coinbase' >&2
        exit 1
    fi
    if ! PRICE=$(printf '%s' "$PRICE_RESPONSE" | jq -er '
        .price | select(type == "string") |
        select(test("^[0-9]+(\\.[0-9]+)?$")) |
        tonumber | select(. > 0 and isfinite)
    ' 2>/dev/null); then
        echo 'Error: Coinbase did not return a valid current NEAR USD price' >&2
        exit 1
    fi
else
    if [[ -z "$PRICE_DATE_ARG" ]]; then
        TARGET_ISO=$(LC_ALL=C date -u -d yesterday +%Y-%m-%d)
    fi
    TARGET_EPOCH=$(LC_ALL=C date -u -d "$TARGET_ISO" +%s)
    TIME_END=$(LC_ALL=C date -u -d "$TARGET_ISO +1 day" +%Y-%m-%d)
    TARGET_LABEL=$(LC_ALL=C date -u -d "$TARGET_ISO" '+%b %d, %Y UTC')
    PRICE_LABEL="close price at $TARGET_LABEL"
    if ! PRICE_RESPONSE=$(curl -fsS --connect-timeout 5 --max-time 20 -G "$PRICE_API/candles" \
        --data-urlencode "granularity=86400" \
        --data-urlencode "start=${TARGET_ISO}T00:00:00Z" \
        --data-urlencode "end=${TIME_END}T00:00:00Z"); then
        echo "Error: could not request the NEAR closing price for $TARGET_ISO UTC from Coinbase" >&2
        exit 1
    fi
    if ! PRICE=$(printf '%s' "$PRICE_RESPONSE" | jq -er --argjson timestamp "$TARGET_EPOCH" '
        select(type == "array") |
        [.[] | select(type == "array") | select(.[0] == $timestamp)] |
        select(length == 1) | .[0] | select(length == 6) |
        .[4] | select(type == "number" and . > 0 and isfinite)
    ' 2>/dev/null); then
        echo "Error: Coinbase did not return a valid NEAR USD daily close for $TARGET_ISO UTC" >&2
        exit 1
    fi
fi
PRICE_FMT=$(awk -v p="$PRICE" 'BEGIN { printf "%.4f", p }')
USD_TOTAL=$(awk -v b="$TOTAL_NEAR" -v p="$PRICE" 'BEGIN { printf "%.0f", b * p }')

# 5 Format the final report
cat <<EOF
${NOW_STR} At block $(format "https://nearblocks.io/blocks/${BLOCK_NUM}" "#${BLOCK_NUM} ${BLOCK_HASH}")

${TOTAL_NEAR} \$NEAR ${NOW_STR}

Daily Gain  ${DAILY_GAIN}
Annual Gain ${ANNUAL_GAIN}
APY         ${APY}

~\$${USD_TOTAL} $(format "https://www.coinbase.com/price/near-protocol" "by \$${PRICE_FMT} ${PRICE_LABEL} on Coinbase")
EOF
