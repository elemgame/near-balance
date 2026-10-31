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

STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/near-balance"
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/${ACCOUNT}.state"

# 1. Resolve the separately installed near-cli-rs executable
if ! NEAR_BIN=$(type -P near); then
    echo "Error: near-cli-rs is required; install it separately (see readme.md)" >&2
    exit 1
fi

# 2. Query account data
NOW_EPOCH=$(date -u +%s)
NOW_STR=$(LC_ALL=C date -u -d "@$NOW_EPOCH" "+%b %d, %Y %H:%M:%S UTC")

# Capture stdout and stderr, near-cli-rs may print the table to either stream
RAW_OUTPUT=$("$NEAR_BIN" account view-account-summary "$ACCOUNT" network-config mainnet now 2>&1)

# Remove ANSI escapes, carriage returns, and UTF-8 non-breaking spaces
CLEAN_OUTPUT=$(printf "%s\n" "$RAW_OUTPUT" | sed -E $'s/\x1b\\[[0-9;]*[a-zA-Z]//g; s/\r//g; s/\xc2\xa0/ /g')

# 3. Parse the block, hash, and balances
BLOCK_NUM=$(printf "%s\n" "$CLEAN_OUTPUT" | awk '/At block #[0-9]+/ {for(i=1;i<=NF;i++) if($i ~ /^#[0-9]+/) {sub("#","",$i); print $i; exit}}')
BLOCK_HASH=$(printf "%s\n" "$CLEAN_OUTPUT" | awk -F'[()]' '/\([1-9A-HJ-NP-Za-km-z]{32,48}\)/ {print $2; exit}')

# Sum the native balance, validator stake, and all delegated stakes
TOTAL_NEAR=$(printf "%s\n" "$CLEAN_OUTPUT" | awk '
    /Native account balance|Validator stake|Delegated stake with/ {
        for (i = 1; i <= NF; i++) {
            if ($i == "NEAR" && i > 1) {
                sum += $(i - 1)
            }
        }
    }
    END { printf "%.8f", sum }
')

# Estimate gains from cached data, or use a baseline APY of 5.09%
read -r DAILY_GAIN ANNUAL_GAIN APY < <(awk -v cur_bal="$TOTAL_NEAR" -v cur_ts="$NOW_EPOCH" -v sfile="$STATE_FILE" '
BEGIN {
    has_prev = 0
    if ((getline line < sfile) > 0) {
        split(line, parts, " ")
        prev_ts = parts[1]
        prev_bal = parts[2]
        dt = cur_ts - prev_ts
        if (dt >= 300 && cur_bal > prev_bal) {
            has_prev = 1
            daily = (cur_bal - prev_bal) * (86400 / dt)
            annual = daily * 365.25
            apy = (annual / prev_bal) * 100
        }
    }
    if (!has_prev) {
        apy = 5.09
        annual = cur_bal * (apy / 100.0)
        daily = annual / 365.25
    }
    printf "%.4f %.2f %.2f\n", daily, annual, apy
}')

# Update the cached sample at most once per hour
if [[ ! -f "$STATE_FILE" ]] || (( NOW_EPOCH - $(awk '{print $1}' "$STATE_FILE") >= 3600 )); then
    echo "$NOW_EPOCH $TOTAL_NEAR" > "$STATE_FILE"
fi

# 4. Fetch the NEAR closing price from the CoinMarketCap API
if [[ -n "${cmc_api_key:-}" ]]; then
    if [[ -z "$PRICE_DATE_ARG" ]]; then
        TARGET_ISO=$(LC_ALL=C date -u -d "yesterday" "+%Y-%m-%d")
    fi

    TARGET_LABEL=$(LC_ALL=C date -u -d "$TARGET_ISO" "+%b %d")
    TIME_START="${TARGET_ISO}T00:00:00Z"
    TIME_END="${TARGET_ISO}T23:59:59Z"

    # Read the header from stdin so the key never appears in curl arguments
    if [[ "$cmc_api_key" == *$'\r'* || "$cmc_api_key" == *$'\n'* ]]; then
        echo "Error: invalid CoinMarketCap API key." >&2
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
        echo "Error: could not retrieve the NEAR price from CoinMarketCap API." >&2
        exit 1
    fi

    PRICE_FMT=$(awk -v p="$CLOSE_PRICE" 'BEGIN { printf "%.4f", p }')
    USD_TOTAL=$(awk -v b="$TOTAL_NEAR" -v p="$CLOSE_PRICE" 'BEGIN { printf "%.0f", b * p }')

fi

# 5. Format the final report
cat <<EOF
${NOW_STR} At block [#${BLOCK_NUM} ${BLOCK_HASH}] (https://nearblocks.io/blocks/${BLOCK_NUM})

${TOTAL_NEAR} \$NEAR ${NOW_STR}

Daily Gain  +${DAILY_GAIN} \$NEAR
Annual Gain +${ANNUAL_GAIN} \$NEAR
APY                 ${APY}%

EOF
if [[ -n "${cmc_api_key:-}" ]]; then
cat <<EOF
~\$${USD_TOTAL} [by \$${PRICE_FMT} close price at ${TARGET_LABEL}](https://coinmarketcap.com/currencies/near-protocol/historical-data/)
EOF
fi
