#!/usr/bin/env bash
# discord-reaction-pulse — Discord API wrapper
#
# Usage:
#   ./reactor.sh add    <channel_id> <message_id> <emoji>
#   ./reactor.sh remove <channel_id> <message_id> <emoji>
#
# Honours these env vars:
#   DISCORD_BOT_TOKEN   required for live calls
#   DISCORD_API_BASE    default https://discord.com/api/v10
#   PULSE_DRY_RUN       if "true", logs the call and returns 0 without curl
#   PULSE_USER_AGENT    default OpenClawDiscordReactionPulse/1.0
#   PULSE_RESPONSE_OUT  optional path to write the API response body
#
# Exit codes:
#   0   success (or dry-run)
#   2   missing argument
#   3   missing DISCORD_BOT_TOKEN
#   4   curl not installed
#   5   non-2xx response from Discord
#   6   429 rate-limited even after one retry

set -eu

cmd="${1:-}"
channel_id="${2:-}"
message_id="${3:-}"
emoji="${4:-}"

if [ -z "$cmd" ] || [ -z "$channel_id" ] || [ -z "$message_id" ] || [ -z "$emoji" ]; then
    echo "usage: reactor.sh <add|remove> <channel_id> <message_id> <emoji>" >&2
    exit 2
fi

api_base="${DISCORD_API_BASE:-https://discord.com/api/v10}"
ua="${PULSE_USER_AGENT:-OpenClawDiscordReactionPulse/1.0}"
dry_run="${PULSE_DRY_RUN:-false}"

# Percent-encode the emoji byte-by-byte. Works for any UTF-8 input
# (Unicode emoji glyphs) and for `name:id` custom-emoji strings.
urlencode() {
    LC_ALL=C
    printf '%s' "$1" \
        | od -An -tx1 -v \
        | tr -d ' \n' \
        | sed 's/\(..\)/%\1/g' \
        | tr 'a-f' 'A-F'
}

encoded_emoji="$(urlencode "$emoji")"

case "$cmd" in
    add|remove) ;;
    *)
        echo "reactor.sh: unknown command '$cmd' (expected add|remove)" >&2
        exit 2
        ;;
esac

method=PUT
[ "$cmd" = "remove" ] && method=DELETE

url="${api_base}/channels/${channel_id}/messages/${message_id}/reactions/${encoded_emoji}/@me"

if [ "$dry_run" = "true" ]; then
    printf 'DRY_RUN reactor %s %s %s emoji=%s url=%s\n' \
        "$cmd" "$channel_id" "$message_id" "$emoji" "$url"
    exit 0
fi

if [ -z "${DISCORD_BOT_TOKEN:-}" ]; then
    echo "reactor.sh: DISCORD_BOT_TOKEN is unset" >&2
    exit 3
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "reactor.sh: curl is not installed" >&2
    exit 4
fi

response_out="${PULSE_RESPONSE_OUT:-}"
if [ -z "$response_out" ]; then
    response_out="$(mktemp 2>/dev/null || echo /tmp/pulse-response.$$)"
    cleanup_response=1
else
    cleanup_response=0
fi

call_once() {
    curl -sS -X "$method" \
        -H "Authorization: Bot ${DISCORD_BOT_TOKEN}" \
        -H "User-Agent: ${ua}" \
        -H "Content-Length: 0" \
        -o "$response_out" \
        -w '%{http_code}' \
        "$url"
}

http_code="$(call_once || echo 000)"

# Honour 429 once
if [ "$http_code" = "429" ]; then
    retry_after=1
    if command -v awk >/dev/null 2>&1 && [ -s "$response_out" ]; then
        # very forgiving JSON peek for retry_after
        retry_after="$(awk '
            {
                while (match($0, /"retry_after"[[:space:]]*:[[:space:]]*[0-9.]+/)) {
                    s = substr($0, RSTART, RLENGTH)
                    sub(/.*:[[:space:]]*/, "", s)
                    print s
                    exit
                }
            }
        ' "$response_out")"
        case "$retry_after" in
            ''|*[!0-9.]*) retry_after=1 ;;
        esac
    fi
    # Round up to next whole second, min 1
    sleep_for="$(awk -v r="$retry_after" 'BEGIN { v = int(r + 0.999); if (v < 1) v = 1; print v }')"
    sleep "$sleep_for"
    http_code="$(call_once || echo 000)"
fi

[ "$cleanup_response" = "1" ] && rm -f "$response_out"

case "$http_code" in
    2*)
        exit 0
        ;;
    429)
        echo "reactor.sh: 429 rate-limited after retry" >&2
        exit 6
        ;;
    *)
        echo "reactor.sh: $method $url failed with HTTP $http_code" >&2
        exit 5
        ;;
esac
