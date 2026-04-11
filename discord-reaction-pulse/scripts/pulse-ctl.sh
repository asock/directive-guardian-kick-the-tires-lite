#!/usr/bin/env bash
# discord-reaction-pulse — CLI control surface
#
# Subcommands:
#   init                            bootstrap memory dir + default state
#   target <channel_id> <msg_id>    set Discord target
#   progress <0-100>                set progress
#   bump <delta>                    adjust progress by delta (signed)
#   tag <feat|bug|test|docs|ship>   set context tag
#   tune <key=value> [...]          set tuning keys
#   react [--emoji <e>]             fire one reaction immediately
#   preview                         show next emoji + interval (no network)
#   start [--foreground]            start the pulse daemon
#   stop                            stop the pulse daemon
#   status                          show full state + computed interval
#   validate                        sanity check
#   reset                           reset state to defaults (with backup)
#   log [N]                         tail last N log entries
#   help                            this message

set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"
skill_dir="$(cd "$script_dir/.." && pwd)"
memory_dir="${OPENCLAW_MEMORY_DIR:-$HOME/.openclaw/memory}/discord-pulse"
state_file="$memory_dir/state"
log_file="$memory_dir/pulse.log"
pid_file="$memory_dir/pulse.pid"
config_file="$skill_dir/config/reactions.conf"
interval_bin="$script_dir/interval.sh"
picker_bin="$script_dir/emoji-picker.sh"
pulse_bin="$script_dir/pulse.sh"
reactor_bin="$script_dir/reactor.sh"

mkdir -p "$memory_dir"

# ── State helpers (mirror pulse.sh) ────────────────────────────────────────

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
    fi
}

state_get() {
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
    local key="$1"
    local value="$2"
    ensure_state
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

backup_state() {
    [ -f "$state_file" ] || return 0
    cp "$state_file" "${state_file}.bak"
}

log_event() {
    local kind="$1"; shift
    local ts
    ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf '%s  %-16s %s\n' "$ts" "$kind" "$*" >>"$log_file"
}

# ── Validators ─────────────────────────────────────────────────────────────

is_int() {
    case "$1" in
        ''|*[!0-9-]*) return 1 ;;
        -) return 1 ;;
        *) return 0 ;;
    esac
}

valid_tag() {
    case "$1" in
        feat|bug|test|docs|ship) return 0 ;;
        *) return 1 ;;
    esac
}

valid_snowflake() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# Tunable keys allow-list with type
tune_apply() {
    local pair="$1"
    local key="${pair%%=*}"
    local value="${pair#*=}"
    if [ "$key" = "$pair" ] || [ -z "$key" ] || [ -z "$value" ]; then
        echo "tune: expected key=value, got '$pair'" >&2
        exit 2
    fi
    case "$key" in
        base_interval_sec|min_interval_sec|max_pulses)
            if ! is_int "$value" || [ "$value" -lt 0 ]; then
                echo "tune: $key must be a non-negative integer" >&2
                exit 2
            fi
            ;;
        curve)
            case "$value" in
                ''|*[!0-9.]*) echo "tune: curve must be numeric" >&2; exit 2 ;;
            esac
            ;;
        *)
            echo "tune: unknown key '$key'" >&2
            echo "  allowed: base_interval_sec min_interval_sec curve max_pulses" >&2
            exit 2
            ;;
    esac
    backup_state
    state_set "$key" "$value"
    echo "tune: $key=$value"
}

# ── Subcommand impls ───────────────────────────────────────────────────────

cmd_init() {
    if [ -f "$state_file" ]; then
        echo "init: state already exists at $state_file"
    else
        ensure_state
        echo "init: created $state_file"
    fi
    log_event INIT "memory=$memory_dir"
}

cmd_target() {
    local channel="${1:-}"
    local message="${2:-}"
    if ! valid_snowflake "$channel" || ! valid_snowflake "$message"; then
        echo "target: channel_id and message_id must be numeric snowflakes" >&2
        exit 2
    fi
    backup_state
    state_set channel_id "$channel"
    state_set message_id "$message"
    echo "target: channel=$channel message=$message"
    log_event TARGET_SET "channel=$channel message=$message"
}

cmd_progress() {
    local p="${1:-}"
    if ! is_int "$p"; then
        echo "progress: value must be an integer 0-100" >&2
        exit 2
    fi
    if [ "$p" -lt 0 ];   then p=0;   fi
    if [ "$p" -gt 100 ]; then p=100; fi
    backup_state
    state_set progress "$p"
    echo "progress: $p"
    log_event PROGRESS "set to $p"
}

cmd_bump() {
    local delta="${1:-}"
    if ! is_int "$delta"; then
        echo "bump: delta must be an integer" >&2
        exit 2
    fi
    ensure_state
    local cur
    cur="$(state_get progress)"; cur="${cur:-0}"
    local new=$((cur + delta))
    if [ "$new" -lt 0 ];   then new=0;   fi
    if [ "$new" -gt 100 ]; then new=100; fi
    backup_state
    state_set progress "$new"
    echo "bump: $cur -> $new"
    log_event PROGRESS "bumped $cur -> $new (delta $delta)"
}

cmd_tag() {
    local t="${1:-}"
    if ! valid_tag "$t"; then
        echo "tag: must be one of feat|bug|test|docs|ship" >&2
        exit 2
    fi
    backup_state
    state_set tag "$t"
    echo "tag: $t"
    log_event TAG_SET "tag=$t"
}

cmd_tune() {
    if [ "$#" -eq 0 ]; then
        echo "tune: expected at least one key=value pair" >&2
        exit 2
    fi
    for pair in "$@"; do
        tune_apply "$pair"
    done
}

cmd_react() {
    local override_emoji=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --emoji)
                override_emoji="${2:-}"
                shift 2
                ;;
            *)
                echo "react: unknown arg '$1'" >&2
                exit 2
                ;;
        esac
    done
    ensure_state
    local channel message
    channel="$(state_get channel_id)"
    message="$(state_get message_id)"
    if [ -z "$channel" ] || [ -z "$message" ]; then
        echo "react: target not set — run 'pulse-ctl target <channel> <message>' first" >&2
        exit 2
    fi
    local emoji
    if [ -n "$override_emoji" ]; then
        emoji="$override_emoji"
    else
        local progress tag cursor picked
        progress="$(state_get progress)"; progress="${progress:-0}"
        tag="$(state_get tag)"; tag="${tag:-feat}"
        cursor="$(state_get tier_cursor)"; cursor="${cursor:-0}"
        picked="$("$picker_bin" "$progress" "$tag" "$cursor" "$config_file")"
        emoji="$(printf '%s\n' "$picked" | sed -n '1p')"
        local next
        next="$(printf '%s\n' "$picked" | sed -n '2p')"
        [ -z "$next" ] && next=0
        state_set tier_cursor "$next"
    fi
    if "$reactor_bin" add "$channel" "$message" "$emoji"; then
        local ts
        ts="$(date +%s)"
        state_set last_pulse_ts "$ts"
        state_set last_emoji "$emoji"
        local count
        count="$(state_get pulse_count)"; count="${count:-0}"
        count=$((count + 1))
        state_set pulse_count "$count"
        echo "react: posted $emoji to $channel/$message"
        log_event PULSE_MANUAL "emoji=$emoji channel=$channel message=$message"
    else
        local rc=$?
        echo "react: reactor.sh exited $rc" >&2
        log_event REACT_FAIL "manual emoji=$emoji rc=$rc"
        exit "$rc"
    fi
}

cmd_preview() {
    ensure_state
    local progress tag cursor base mn curve picked emoji next interval band
    progress="$(state_get progress)"; progress="${progress:-0}"
    tag="$(state_get tag)"; tag="${tag:-feat}"
    cursor="$(state_get tier_cursor)"; cursor="${cursor:-0}"
    base="$(state_get base_interval_sec)"; base="${base:-300}"
    mn="$(state_get min_interval_sec)"; mn="${mn:-15}"
    curve="$(state_get curve)"; curve="${curve:-1.8}"

    picked="$("$picker_bin" "$progress" "$tag" "$cursor" "$config_file")"
    emoji="$(printf '%s\n' "$picked" | sed -n '1p')"
    next="$(printf '%s\n' "$picked" | sed -n '2p')"
    interval="$("$interval_bin" "$progress" "$base" "$mn" "$curve")"

    if   [ "$progress" -lt 25 ]; then band=seedling
    elif [ "$progress" -lt 50 ]; then band=building
    elif [ "$progress" -lt 75 ]; then band=pushing
    elif [ "$progress" -lt 95 ]; then band=crunching
    else                              band=shipping
    fi

    cat <<EOF
preview:
  progress       $progress%
  band           $band
  tag            $tag
  next emoji     $emoji
  next interval  ${interval}s
  next cursor    $next
EOF
}

cmd_start() {
    local foreground=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --foreground|-f) foreground=1; shift ;;
            *) echo "start: unknown arg '$1'" >&2; exit 2 ;;
        esac
    done

    if [ -f "$pid_file" ]; then
        local existing
        existing="$(cat "$pid_file" 2>/dev/null || true)"
        if [ -n "$existing" ] && kill -0 "$existing" 2>/dev/null; then
            echo "start: daemon already running (pid $existing)"
            exit 0
        else
            rm -f "$pid_file"
        fi
    fi

    if [ "$foreground" = "1" ]; then
        exec "$pulse_bin"
    fi

    nohup "$pulse_bin" >>"$log_file" 2>&1 &
    local pid=$!
    # nohup forks; pulse.sh writes its own pid file when it claims_pid().
    echo "start: launched daemon (shell pid $pid) — see $log_file"
}

cmd_stop() {
    if [ ! -f "$pid_file" ]; then
        echo "stop: no daemon running"
        return 0
    fi
    local pid
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [ -z "$pid" ]; then
        rm -f "$pid_file"
        echo "stop: stale pid file removed"
        return 0
    fi
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid"
        # give it a moment to clean up
        local i=0
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 5 ]; do
            sleep 1
            i=$((i + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
        echo "stop: signaled pid $pid"
        log_event DAEMON_KILL "pid=$pid"
    else
        echo "stop: pid $pid not running"
    fi
    rm -f "$pid_file"
}

cmd_status() {
    ensure_state
    local progress tag base mn curve cursor channel message last_ts last_emoji count max
    progress="$(state_get progress)"; progress="${progress:-0}"
    tag="$(state_get tag)"; tag="${tag:-feat}"
    base="$(state_get base_interval_sec)"; base="${base:-300}"
    mn="$(state_get min_interval_sec)"; mn="${mn:-15}"
    curve="$(state_get curve)"; curve="${curve:-1.8}"
    cursor="$(state_get tier_cursor)"; cursor="${cursor:-0}"
    channel="$(state_get channel_id)"
    message="$(state_get message_id)"
    last_ts="$(state_get last_pulse_ts)"; last_ts="${last_ts:-0}"
    last_emoji="$(state_get last_emoji)"
    count="$(state_get pulse_count)"; count="${count:-0}"
    max="$(state_get max_pulses)"; max="${max:-0}"

    local interval band
    interval="$("$interval_bin" "$progress" "$base" "$mn" "$curve")"
    if   [ "$progress" -lt 25 ]; then band=seedling
    elif [ "$progress" -lt 50 ]; then band=building
    elif [ "$progress" -lt 75 ]; then band=pushing
    elif [ "$progress" -lt 95 ]; then band=crunching
    else                              band=shipping
    fi

    local daemon_state="stopped"
    if [ -f "$pid_file" ]; then
        local pid
        pid="$(cat "$pid_file" 2>/dev/null || true)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            daemon_state="running (pid $pid)"
        else
            daemon_state="stale pid $pid"
        fi
    fi

    cat <<EOF
discord-reaction-pulse status
─────────────────────────────
  daemon         $daemon_state
  progress       $progress%   (band: $band)
  tag            $tag
  target         channel=${channel:-<unset>}  message=${message:-<unset>}
  cadence        base=${base}s  min=${mn}s  curve=$curve
  next interval  ${interval}s
  pulses fired   $count${max:+ (max $max)}
  last emoji     ${last_emoji:-<none>}
  last pulse     ${last_ts:-0}
  state file     $state_file
  log file       $log_file
EOF

    if [ -f "$log_file" ]; then
        echo
        echo "  recent log (last 10):"
        tail -n 10 "$log_file" | sed 's/^/    /'
    fi
}

cmd_validate() {
    local errors=0
    ensure_state

    echo "validate: state file"
    for key in progress channel_id message_id tag base_interval_sec \
               min_interval_sec curve max_pulses; do
        local v
        v="$(state_get "$key")"
        printf '  %-20s %s\n' "$key" "${v:-<empty>}"
    done

    local progress base mn curve tag
    progress="$(state_get progress)"
    base="$(state_get base_interval_sec)"
    mn="$(state_get min_interval_sec)"
    curve="$(state_get curve)"
    tag="$(state_get tag)"

    if ! is_int "$progress" || [ "$progress" -lt 0 ] || [ "$progress" -gt 100 ]; then
        echo "  ✗ progress out of range: $progress"
        errors=$((errors + 1))
    fi
    if ! is_int "$base" || [ "$base" -lt 1 ]; then
        echo "  ✗ base_interval_sec invalid: $base"
        errors=$((errors + 1))
    fi
    if ! is_int "$mn" || [ "$mn" -lt 1 ]; then
        echo "  ✗ min_interval_sec invalid: $mn"
        errors=$((errors + 1))
    fi
    if [ -n "$base" ] && [ -n "$mn" ] && is_int "$base" && is_int "$mn" \
       && [ "$mn" -gt "$base" ]; then
        echo "  ✗ min_interval_sec ($mn) greater than base_interval_sec ($base)"
        errors=$((errors + 1))
    fi
    case "$curve" in
        ''|*[!0-9.]*) echo "  ✗ curve not numeric: $curve"; errors=$((errors + 1)) ;;
    esac
    if ! valid_tag "$tag"; then
        echo "  ✗ tag invalid: $tag"
        errors=$((errors + 1))
    fi

    echo "validate: config"
    if [ ! -f "$config_file" ]; then
        echo "  ✗ missing config: $config_file"
        errors=$((errors + 1))
    else
        echo "  ✓ $config_file"
    fi

    echo "validate: env"
    if [ -z "${DISCORD_BOT_TOKEN:-}" ]; then
        echo "  ⚠ DISCORD_BOT_TOKEN unset (live reactions will fail)"
    else
        echo "  ✓ DISCORD_BOT_TOKEN set"
    fi

    if [ "$errors" -eq 0 ]; then
        echo "validate: OK"
        return 0
    fi
    echo "validate: $errors error(s)"
    return 1
}

cmd_reset() {
    backup_state
    default_state >"$state_file"
    echo "reset: state restored to defaults (backup at ${state_file}.bak)"
    log_event RESET "state reset"
}

cmd_log() {
    local n="${1:-25}"
    if ! is_int "$n" || [ "$n" -lt 1 ]; then
        echo "log: N must be a positive integer" >&2
        exit 2
    fi
    if [ ! -f "$log_file" ]; then
        echo "log: $log_file does not exist yet"
        return 0
    fi
    tail -n "$n" "$log_file"
}

cmd_help() {
    sed -n '2,21p' "$0"
}

# ── Dispatch ───────────────────────────────────────────────────────────────

cmd="${1:-help}"
shift || true

case "$cmd" in
    init)      cmd_init "$@" ;;
    target)    cmd_target "$@" ;;
    progress)  cmd_progress "$@" ;;
    bump)      cmd_bump "$@" ;;
    tag)       cmd_tag "$@" ;;
    tune)      cmd_tune "$@" ;;
    react)     cmd_react "$@" ;;
    preview)   cmd_preview "$@" ;;
    start)     cmd_start "$@" ;;
    stop)      cmd_stop "$@" ;;
    status)    cmd_status "$@" ;;
    validate)  cmd_validate "$@" ;;
    reset)     cmd_reset "$@" ;;
    log)       cmd_log "$@" ;;
    help|-h|--help) cmd_help ;;
    *)
        echo "pulse-ctl: unknown command '$cmd'" >&2
        cmd_help >&2
        exit 2
        ;;
esac
