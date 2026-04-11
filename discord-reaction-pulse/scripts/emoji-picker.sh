#!/usr/bin/env bash
# discord-reaction-pulse — emoji picker (pure-ish)
#
# Usage:
#   ./emoji-picker.sh <progress> <tag> <cursor> [config_file]
#
# Outputs two lines on stdout:
#   <chosen_emoji>
#   <next_cursor>
#
# Reads `config/reactions.conf` (or the path passed as $4) to find the
# emoji list for the (band, tag) cell. Falls back to (band, _) if the
# specific tag is missing. The cursor advances round-robin through the
# list so callers can avoid repeating the same emoji back-to-back.
#
# Bands:
#   seedling   0-24
#   building   25-49
#   pushing    50-74
#   crunching  75-94
#   shipping   95-100

set -eu

progress="${1:-0}"
tag="${2:-_}"
cursor="${3:-0}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
config="${4:-$script_dir/../config/reactions.conf}"

# Sanitize numeric inputs
case "$progress" in
    ''|*[!0-9-]*) progress=0 ;;
esac
case "$cursor" in
    ''|*[!0-9]*) cursor=0 ;;
esac

if [ "$progress" -lt 0 ];   then progress=0;   fi
if [ "$progress" -gt 100 ]; then progress=100; fi

# Map progress → band
band() {
    if [ "$1" -lt 25 ];  then echo seedling;  return; fi
    if [ "$1" -lt 50 ];  then echo building;  return; fi
    if [ "$1" -lt 75 ];  then echo pushing;   return; fi
    if [ "$1" -lt 95 ];  then echo crunching; return; fi
    echo shipping
}

current_band="$(band "$progress")"

# Sanitize tag — only allow our known set, anything else falls to generic.
case "$tag" in
    feat|bug|test|docs|ship|_) ;;
    *) tag=_ ;;
esac

if [ ! -f "$config" ]; then
    # Hard-coded fallback so the picker still works without a config file.
    # Mirrors the seedling/_ row only — caller should provide a config for
    # the full table.
    echo "🌱"
    echo "0"
    exit 0
fi

# Look up <band>:<tag>=... then fall back to <band>:_=...
lookup() {
    awk -F'=' -v key="$1" '
        $0 ~ /^[[:space:]]*#/ { next }
        $0 ~ /^[[:space:]]*$/ { next }
        {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
            if ($1 == key) {
                # join everything after the first = back together
                line = $2
                for (i = 3; i <= NF; i++) line = line "=" $i
                print line
                exit
            }
        }
    ' "$config"
}

list="$(lookup "${current_band}:${tag}")"
if [ -z "$list" ]; then
    list="$(lookup "${current_band}:_")"
fi
if [ -z "$list" ]; then
    # Last-resort hard-coded fallback per band
    case "$current_band" in
        seedling)  list="🌱" ;;
        building)  list="🔨" ;;
        pushing)   list="⏳" ;;
        crunching) list="🔥" ;;
        shipping)  list="🚀" ;;
    esac
fi

# Split list on commas (no leading/trailing space). Use awk to count and
# select an entry by index — works correctly with multibyte UTF-8 because
# we never index into a single emoji's bytes.
selected_and_next="$(
    awk -v list="$list" -v cur="$cursor" '
    BEGIN {
        n = split(list, arr, /,/)
        if (n == 0) { print ""; print 0; exit }
        idx = (cur % n) + 1
        if (idx < 1) idx = 1
        chosen = arr[idx]
        # Trim whitespace
        sub(/^[[:space:]]+/, "", chosen)
        sub(/[[:space:]]+$/, "", chosen)
        print chosen
        print (cur + 1) % n
    }
    '
)"

# Output: emoji \n next_cursor
printf '%s\n' "$selected_and_next"
