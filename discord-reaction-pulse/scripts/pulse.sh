#!/usr/bin/env bash
# discord-reaction-pulse — daemon / one-shot loop
#
# Usage:
#   ./pulse.sh                    # run loop in foreground
#   ./pulse.sh --once             # fire exactly one reaction and exit
#   ./pulse.sh --no-react         # exercise pipeline without firing (still updates state)
#
# Env:
#   OPENCLAW_MEMORY_DIR  default ~/.openclaw/memory
#   PULSE_DRY_RUN        if "true", reactor.sh just logs the call
#   PULSE_REACTOR_BIN    override path to reactor.sh (used by tests)
#   PULSE_SLEEP_BIN      override sleep command (used by tests)
#
# Reads + writes ~/.openclaw/memory/discord-pulse/{state,pulse.log,pulse.pid}.

set -eu

once=0
no_react=0
for arg in "$@"; do
    case "$arg" in
        --once) once=1 ;;
        --no-react) no_react=1 ;;
        --help|-h)
            sed -n '2,12p' "$0"
            exit 0
            ;;
        *)
            echo "pulse.sh: unknown arg '$arg'" >&2
            exit 2
            ;;
    esac
done

script_dir="$(cd "$(dirname "$0")" && pwd)"
skill_dir="$(cd "$script_dir/.." && pwd)"

memory_dir="${OPENCLAW_MEMORY_DIR:-$HOME/.openclaw/memory}/discord-pulse"
state_file="$memory_dir/state"
log_file="$memory_dir/pulse.log"
pid_file="$memory_dir/pulse.pid"
config_file="$skill_dir/config/reactions.conf"
interval_bin="$script_dir/interval.sh"
picker_bin="$script_dir/emoji-picker.sh"
reactor_bin="${PULSE_REACTOR_BIN:-$script_dir/reactor.sh}"
sleep_bin="${PULSE_SLEEP_BIN:-sleep}"

mkdir -p "$memory_dir"

# ── State helpers ──────────────────────────────────────────────────────────

default_state() {
    cat <<'EOF'
progress=0
channel_id=
message_id=
tag=feat
base_interval_sec=300
min_interval_sec=15
curve=1.8
max_pulses=0
last_pulse_ts=0
last_emoji=
pulse_count=0
tier_cursor=0
EOF
}

ensure_state() {
    if [ ! -f "$state_file" ]; then
        default_state >"$state_file"
        log_event BOOTSTRAP "created default state at $state_file"
    fi
}

state_get() {
    # state_get <key>
    awk -F'=' -v k="$1" '
        $0 ~ /^[[:space:]]*#/ { next }
        $0 ~ /^[[:space:]]*$/ { next }
        {
            key = $1
            sub(/^[[:space:]]+/, "", key)
            sub(/[[:space:]]+$/, "", key)
            if (key == k) {
                line = $2
                for (i = 3; i <= NF; i++) line = line "=" $i
                sub(/^[[:space:]]+/, "", line)
                sub(/[[:space:]]+$/, "", line)
                print line
                exit
            }
        }
    ' "$state_file"
}

state_set() {
    # state_set <key> <value>   (creates key if missing)
    local key="$1"
    local value="$2"
    local tmp
    tmp="$(mktemp "${state_file}.XXXX")"
    awk -F'=' -v k="$key" -v v="$value" '
        BEGIN { written = 0 }
        $0 ~ /^[[:space:]]*#/ { print; next }
        $0 ~ /^[[:space:]]*$/ { print; next }
        {
            key = $1
            sub(/^[[:space:]]+/, "", key)
            sub(/[[:space:]]+$/, "", key)
            if (key == k) {
                print key "=" v
                written = 1
                next
            }
            print
        }
        END {
            if (!written) print k "=" v
        }
    ' "$state_file" >"$tmp"
    mv "$tmp" "$state_file"
}

# ── Logging ────────────────────────────────────────────────────────────────

log_event() {
    # log_event <kind> <message...>
    local kind="$1"; shift
    local ts
    ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf '%s  %-16s %s\n' "$ts" "$kind" "$*" >>"$log_file"
    rotate_log_if_needed
}

rotate_log_if_needed() {
    [ -f "$log_file" ] || return 0
    local lines
    lines="$(wc -l <"$log_file" 2>/dev/null | tr -d ' ')"
    [ -z "$lines" ] && return 0
    if [ "$lines" -gt 500 ]; then
        local tmp
        tmp="$(mktemp "${log_file}.XXXX")"
        tail -n 250 "$log_file" >"$tmp"
        mv "$tmp" "$log_file"
        printf '%s  %-16s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" LOG_ROTATED \
            "kept last 250 lines" >>"$log_file"
    fi
}

# ── PID handling ───────────────────────────────────────────────────────────

claim_pid() {
    if [ -f "$pid_file" ]; then
        local existing
        existing="$(cat "$pid_file" 2>/dev/null || true)"
        if [ -n "$existing" ] && kill -0 "$existing" 2>/dev/null; then
            echo "pulse.sh: daemon already running (pid $existing)" >&2
            log_event LOCK_HELD "pid $existing already running"
            exit 7
        fi
    fi
    echo "$$" >"$pid_file"
    trap 'release_pid' EXIT INT TERM
}

release_pid() {
    if [ -f "$pid_file" ]; then
        local owner
        owner="$(cat "$pid_file" 2>/dev/null || true)"
        if [ "$owner" = "$$" ]; then
            rm -f "$pid_file"
        fi
    fi
}

# ── One pulse iteration ────────────────────────────────────────────────────

clamp_progress() {
    local p="$1"
    case "$p" in
        ''|*[!0-9-]*) p=0 ;;
    esac
    if [ "$p" -lt 0 ];   then p=0;   log_event PROGRESS_CLAMPED "raised to 0";   fi
    if [ "$p" -gt 100 ]; then p=100; log_event PROGRESS_CLAMPED "lowered to 100"; fi
    echo "$p"
}

do_one_pulse() {
    local progress tag base mn curve cursor channel message
    progress="$(state_get progress)"
    progress="$(clamp_progress "${progress:-0}")"
    state_set progress "$progress"

    tag="$(state_get tag)"
    [ -z "$tag" ] && tag=feat
    base="$(state_get base_interval_sec)"; base="${base:-300}"
    mn="$(state_get min_interval_sec)"; mn="${mn:-15}"
    curve="$(state_get curve)"; curve="${curve:-1.8}"
    cursor="$(state_get tier_cursor)"; cursor="${cursor:-0}"
    channel="$(state_get channel_id)"
    message="$(state_get message_id)"

    local interval
    interval="$("$interval_bin" "$progress" "$base" "$mn" "$curve")"

    local picked emoji next_cursor
    picked="$("$picker_bin" "$progress" "$tag" "$cursor" "$config_file")"
    emoji="$(printf '%s\n' "$picked" | sed -n '1p')"
    next_cursor="$(printf '%s\n' "$picked" | sed -n '2p')"
    [ -z "$next_cursor" ] && next_cursor=0

    local band
    if   [ "$progress" -lt 25 ]; then band=seedling
    elif [ "$progress" -lt 50 ]; then band=building
    elif [ "$progress" -lt 75 ]; then band=pushing
    elif [ "$progress" -lt 95 ]; then band=crunching
    else                              band=shipping
    fi

    if [ "$no_react" = "1" ]; then
        log_event PULSE_DRY \
            "band=$band tag=$tag emoji=$emoji progress=$progress next=${interval}s"
    elif [ -z "$channel" ] || [ -z "$message" ]; then
        log_event NO_TARGET \
            "skipped: channel_id or message_id is empty (progress=$progress)"
    else
        if "$reactor_bin" add "$channel" "$message" "$emoji" 2>>"$log_file"; then
            local ts
            ts="$(date +%s)"
            state_set last_pulse_ts "$ts"
            state_set last_emoji "$emoji"
            local count
            count="$(state_get pulse_count)"; count="${count:-0}"
            count=$((count + 1))
            state_set pulse_count "$count"
            log_event PULSE \
                "band=$band tag=$tag emoji=$emoji progress=$progress next=${interval}s"
        else
            log_event REACT_FAIL \
                "band=$band tag=$tag emoji=$emoji progress=$progress (see stderr above)"
        fi
    fi

    state_set tier_cursor "$next_cursor"

    # Echo the computed interval so the loop / one-shot caller knows how
    # long to sleep without re-reading state.
    echo "$interval"
}

# ── Main ───────────────────────────────────────────────────────────────────

ensure_state

if [ "$once" = "1" ]; then
    do_one_pulse >/dev/null
    exit 0
fi

claim_pid
log_event DAEMON_START "pid=$$ memory=$memory_dir"

while :; do
    interval="$(do_one_pulse)"

    # Check completion / max_pulses to decide if we should exit
    progress="$(state_get progress)"
    progress="${progress:-0}"
    max_pulses="$(state_get max_pulses)"; max_pulses="${max_pulses:-0}"
    pulse_count="$(state_get pulse_count)"; pulse_count="${pulse_count:-0}"

    if [ "$progress" = "100" ]; then
        log_event PULSE_COMPLETE "progress=100 pulse_count=$pulse_count"
        break
    fi
    if [ "$max_pulses" -gt 0 ] && [ "$pulse_count" -ge "$max_pulses" ]; then
        log_event PULSE_LIMIT "pulse_count=$pulse_count max=$max_pulses"
        break
    fi

    "$sleep_bin" "$interval"
done

log_event DAEMON_STOP "pid=$$"
