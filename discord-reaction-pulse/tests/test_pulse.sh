#!/usr/bin/env bash
# discord-reaction-pulse — offline test harness
#
# All tests stub out reactor.sh (so no network) and sleep (so no waiting).
# Each test runs against a temp OPENCLAW_MEMORY_DIR so they don't pollute
# the user's real memory dir.

set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
skill_dir="$(cd "$script_dir/.." && pwd)"

PULSE_CTL="$skill_dir/scripts/pulse-ctl.sh"
PULSE="$skill_dir/scripts/pulse.sh"
INTERVAL="$skill_dir/scripts/interval.sh"
PICKER="$skill_dir/scripts/emoji-picker.sh"
REACTOR="$skill_dir/scripts/reactor.sh"
CONFIG="$skill_dir/config/reactions.conf"

PASS=0
FAIL=0
FAILED_TESTS=""

red()   { printf '\033[31m%s\033[0m' "$1"; }
green() { printf '\033[32m%s\033[0m' "$1"; }
yellow(){ printf '\033[33m%s\033[0m' "$1"; }

assert_eq() {
    # assert_eq <name> <expected> <actual>
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf '  %s %s\n' "$(green ✓)" "$name"
        PASS=$((PASS + 1))
    else
        printf '  %s %s\n      expected: %s\n      actual:   %s\n' \
            "$(red ✗)" "$name" "$expected" "$actual"
        FAIL=$((FAIL + 1))
        FAILED_TESTS="$FAILED_TESTS\n  $name"
    fi
}

assert_in_range() {
    # assert_in_range <name> <low> <high> <actual>
    local name="$1" low="$2" high="$3" actual="$4"
    if [ "$actual" -ge "$low" ] && [ "$actual" -le "$high" ]; then
        printf '  %s %s (%s in [%s..%s])\n' "$(green ✓)" "$name" "$actual" "$low" "$high"
        PASS=$((PASS + 1))
    else
        printf '  %s %s\n      wanted in [%s..%s], got: %s\n' \
            "$(red ✗)" "$name" "$low" "$high" "$actual"
        FAIL=$((FAIL + 1))
        FAILED_TESTS="$FAILED_TESTS\n  $name"
    fi
}

assert_contains() {
    # assert_contains <name> <needle> <haystack>
    local name="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*)
            printf '  %s %s\n' "$(green ✓)" "$name"
            PASS=$((PASS + 1))
            ;;
        *)
            printf '  %s %s\n      missing substring: %s\n      haystack: %s\n' \
                "$(red ✗)" "$name" "$needle" "$haystack"
            FAIL=$((FAIL + 1))
            FAILED_TESTS="$FAILED_TESTS\n  $name"
            ;;
    esac
}

assert_exit() {
    # assert_exit <name> <expected_rc> <actual_rc>
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf '  %s %s\n' "$(green ✓)" "$name"
        PASS=$((PASS + 1))
    else
        printf '  %s %s\n      expected exit %s, got %s\n' \
            "$(red ✗)" "$name" "$expected" "$actual"
        FAIL=$((FAIL + 1))
        FAILED_TESTS="$FAILED_TESTS\n  $name"
    fi
}

setup_sandbox() {
    SANDBOX="$(mktemp -d)"
    export OPENCLAW_MEMORY_DIR="$SANDBOX"
    mkdir -p "$SANDBOX/discord-pulse"

    # stub reactor: writes its args to a file, returns 0
    STUB_DIR="$SANDBOX/stubs"
    mkdir -p "$STUB_DIR"
    cat >"$STUB_DIR/reactor.sh" <<'STUB'
#!/usr/bin/env bash
echo "STUB_REACT $*" >>"$STUB_LOG"
exit 0
STUB
    chmod +x "$STUB_DIR/reactor.sh"
    export STUB_LOG="$SANDBOX/stub-react.log"
    : >"$STUB_LOG"

    # stub sleep: instant
    cat >"$STUB_DIR/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$STUB_DIR/sleep"

    export PULSE_REACTOR_BIN="$STUB_DIR/reactor.sh"
    export PULSE_SLEEP_BIN="$STUB_DIR/sleep"
}

teardown_sandbox() {
    [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
    unset SANDBOX OPENCLAW_MEMORY_DIR PULSE_REACTOR_BIN PULSE_SLEEP_BIN STUB_LOG
}

section() {
    printf '\n%s %s\n' "$(yellow ▸)" "$1"
}

# ─────────────────────────────────────────────────────────────────────────
# 1. interval.sh — progress → seconds
# ─────────────────────────────────────────────────────────────────────────
section "interval.sh"

result="$("$INTERVAL" 0 300 15 1.8)"
assert_eq "interval@0% == 300" "300" "$result"

result="$("$INTERVAL" 100 300 15 1.8)"
assert_eq "interval@100% == 15" "15" "$result"

result="$("$INTERVAL" 50 300 15 1.8)"
assert_in_range "interval@50% in (15, 300)" 16 299 "$result"

# Monotonic check: interval must be non-increasing as progress climbs
prev="$("$INTERVAL" 0 300 15 1.8)"
ok=1
for p in 10 20 30 40 50 60 70 80 90 100; do
    cur="$("$INTERVAL" "$p" 300 15 1.8)"
    if [ "$cur" -gt "$prev" ]; then
        ok=0
        break
    fi
    prev="$cur"
done
assert_eq "interval is monotonically non-increasing" "1" "$ok"

# Curve sanity: with factor=(1-p)^c and c>1, raising c shrinks the interval
# at every p>0 (the curve sits below the linear baseline everywhere). The
# strongest divergence is around the midpoint, so check it there.
mid_linear="$("$INTERVAL" 50 300 15 1.0)"
mid_steep="$("$INTERVAL" 50 300 15 2.5)"
if [ "$mid_steep" -lt "$mid_linear" ]; then
    assert_eq "higher curve = more aggressive cadence at midpoint" "1" "1"
else
    assert_eq "higher curve = more aggressive cadence at midpoint" "1" "0"
fi
# And the inverse: curve < 1 should be slower than linear at midpoint
mid_soft="$("$INTERVAL" 50 300 15 0.5)"
if [ "$mid_soft" -gt "$mid_linear" ]; then
    assert_eq "curve<1 = softer cadence at midpoint" "1" "1"
else
    assert_eq "curve<1 = softer cadence at midpoint" "1" "0"
fi

# Clamping
result="$("$INTERVAL" -50 300 15 1.8)"
assert_eq "interval clamps negative progress to 0" "300" "$result"
result="$("$INTERVAL" 9999 300 15 1.8)"
assert_eq "interval clamps progress > 100 to 100" "15" "$result"

# Inverted base/min should be auto-corrected
result="$("$INTERVAL" 0 15 300 1.8)"
assert_eq "interval auto-swaps inverted base/min" "300" "$result"

# ─────────────────────────────────────────────────────────────────────────
# 2. emoji-picker.sh — band + tag → emoji + cursor
# ─────────────────────────────────────────────────────────────────────────
section "emoji-picker.sh"

picked="$("$PICKER" 0 feat 0 "$CONFIG")"
emoji="$(printf '%s\n' "$picked" | sed -n '1p')"
next="$(printf '%s\n' "$picked" | sed -n '2p')"
[ -n "$emoji" ] && assert_eq "seedling/feat picks something" "1" "1" \
    || assert_eq "seedling/feat picks something" "1" "0"
case "$next" in
    ''|*[!0-9]*) assert_eq "next cursor is integer" "1" "0" ;;
    *) assert_eq "next cursor is integer" "1" "1" ;;
esac

# Round-robin: two consecutive picks with advancing cursor must differ
# (assuming the picked list has >1 entry — it does for feat in seedling)
p1="$("$PICKER" 0 feat 0 "$CONFIG" | sed -n '1p')"
p2="$("$PICKER" 0 feat 1 "$CONFIG" | sed -n '1p')"
if [ "$p1" != "$p2" ]; then
    assert_eq "round-robin yields different consecutive picks" "1" "1"
else
    assert_eq "round-robin yields different consecutive picks" "1" "0"
fi

# Band boundaries
p="$("$PICKER" 24 _ 0 "$CONFIG" | sed -n '1p')"
seedling_default="$(awk -F'=' '$1=="seedling:_" {print $2; exit}' "$CONFIG" \
    | awk -F',' '{print $1}')"
assert_eq "p=24 is seedling band" "$seedling_default" "$p"

p="$("$PICKER" 25 _ 0 "$CONFIG" | sed -n '1p')"
building_default="$(awk -F'=' '$1=="building:_" {print $2; exit}' "$CONFIG" \
    | awk -F',' '{print $1}')"
assert_eq "p=25 is building band" "$building_default" "$p"

p="$("$PICKER" 95 _ 0 "$CONFIG" | sed -n '1p')"
shipping_default="$(awk -F'=' '$1=="shipping:_" {print $2; exit}' "$CONFIG" \
    | awk -F',' '{print $1}')"
assert_eq "p=95 is shipping band" "$shipping_default" "$p"

p="$("$PICKER" 100 _ 0 "$CONFIG" | sed -n '1p')"
assert_eq "p=100 is shipping band" "$shipping_default" "$p"

# Unknown tag falls back to generic
p_known="$("$PICKER" 50 _ 0 "$CONFIG" | sed -n '1p')"
p_unknown="$("$PICKER" 50 totally-bogus-tag 0 "$CONFIG" | sed -n '1p')"
assert_eq "unknown tag falls back to generic" "$p_known" "$p_unknown"

# ─────────────────────────────────────────────────────────────────────────
# 3. reactor.sh — dry run mode + URL encoding
# ─────────────────────────────────────────────────────────────────────────
section "reactor.sh"

output="$(PULSE_DRY_RUN=true "$REACTOR" add 111 222 '🚀' 2>&1)"
rc=$?
assert_exit "dry-run reactor returns 0" "0" "$rc"
assert_contains "dry-run includes channel" "111" "$output"
assert_contains "dry-run includes message" "222" "$output"
assert_contains "dry-run includes encoded emoji" "%F0%9F%9A%80" "$output"

output="$(PULSE_DRY_RUN=true "$REACTOR" add 1 2 'name:12345' 2>&1)"
rc=$?
assert_exit "dry-run with custom emoji returns 0" "0" "$rc"
assert_contains "custom emoji name encoded" "name" "$output"

# Missing args
"$REACTOR" add 2>/dev/null
assert_exit "missing args exits 2" "2" "$?"

# Unknown command
"$REACTOR" frobnicate 1 2 'X' 2>/dev/null
assert_exit "unknown command exits 2" "2" "$?"

# Missing token, no dry run, no curl-stub: should fail with 3
unset DISCORD_BOT_TOKEN
PULSE_DRY_RUN=false "$REACTOR" add 1 2 '🚀' 2>/dev/null
assert_exit "missing token exits 3" "3" "$?"

# ─────────────────────────────────────────────────────────────────────────
# 4. pulse-ctl.sh — state CRUD + validators
# ─────────────────────────────────────────────────────────────────────────
section "pulse-ctl.sh"

setup_sandbox

"$PULSE_CTL" init >/dev/null
[ -f "$SANDBOX/discord-pulse/state" ]
assert_exit "init creates state file" "0" "$?"

"$PULSE_CTL" progress 42 >/dev/null
got="$(awk -F'=' '$1=="progress" {print $2}' "$SANDBOX/discord-pulse/state")"
assert_eq "progress 42 persisted" "42" "$got"

"$PULSE_CTL" bump 8 >/dev/null
got="$(awk -F'=' '$1=="progress" {print $2}' "$SANDBOX/discord-pulse/state")"
assert_eq "bump +8 from 42 -> 50" "50" "$got"

"$PULSE_CTL" bump -200 >/dev/null
got="$(awk -F'=' '$1=="progress" {print $2}' "$SANDBOX/discord-pulse/state")"
assert_eq "bump clamps to 0 (not negative)" "0" "$got"

"$PULSE_CTL" progress 9999 >/dev/null 2>&1
got="$(awk -F'=' '$1=="progress" {print $2}' "$SANDBOX/discord-pulse/state")"
assert_eq "progress 9999 clamped to 100" "100" "$got"

"$PULSE_CTL" tag bug >/dev/null
got="$(awk -F'=' '$1=="tag" {print $2}' "$SANDBOX/discord-pulse/state")"
assert_eq "tag bug persisted" "bug" "$got"

"$PULSE_CTL" tag wrongtag >/dev/null 2>&1
assert_exit "invalid tag rejected" "2" "$?"

"$PULSE_CTL" target 123456789012345678 234567890123456789 >/dev/null
got="$(awk -F'=' '$1=="channel_id" {print $2}' "$SANDBOX/discord-pulse/state")"
assert_eq "channel_id persisted" "123456789012345678" "$got"

"$PULSE_CTL" target abc def >/dev/null 2>&1
assert_exit "non-numeric snowflake rejected" "2" "$?"

"$PULSE_CTL" tune base_interval_sec=600 curve=2.5 >/dev/null
got="$(awk -F'=' '$1=="base_interval_sec" {print $2}' "$SANDBOX/discord-pulse/state")"
assert_eq "tune base_interval_sec=600" "600" "$got"
got="$(awk -F'=' '$1=="curve" {print $2}' "$SANDBOX/discord-pulse/state")"
assert_eq "tune curve=2.5" "2.5" "$got"

"$PULSE_CTL" tune unknownkey=1 >/dev/null 2>&1
assert_exit "tune rejects unknown key" "2" "$?"

"$PULSE_CTL" tune base_interval_sec=-5 >/dev/null 2>&1
assert_exit "tune rejects negative integer" "2" "$?"

# preview should not require a target
output="$("$PULSE_CTL" preview 2>&1)"
assert_contains "preview shows progress" "progress" "$output"
assert_contains "preview shows next interval" "next interval" "$output"

# status sanity
output="$("$PULSE_CTL" status 2>&1)"
assert_contains "status shows daemon line" "daemon" "$output"
assert_contains "status shows progress" "progress" "$output"

# validate should pass on default state
"$PULSE_CTL" validate >/dev/null 2>&1
assert_exit "validate passes after init" "0" "$?"

# Reset
"$PULSE_CTL" reset >/dev/null
got="$(awk -F'=' '$1=="progress" {print $2}' "$SANDBOX/discord-pulse/state")"
assert_eq "reset zeroes progress" "0" "$got"
[ -f "$SANDBOX/discord-pulse/state.bak" ]
assert_exit "reset created backup" "0" "$?"

teardown_sandbox

# ─────────────────────────────────────────────────────────────────────────
# 5. pulse-ctl react — uses stubbed reactor
# ─────────────────────────────────────────────────────────────────────────
section "pulse-ctl react (stubbed reactor)"

setup_sandbox
"$PULSE_CTL" init >/dev/null
"$PULSE_CTL" target 111 222 >/dev/null
"$PULSE_CTL" tag feat >/dev/null
"$PULSE_CTL" progress 30 >/dev/null

# pulse-ctl react calls reactor.sh directly (not via PULSE_REACTOR_BIN),
# so we use PULSE_DRY_RUN to keep it offline.
output="$(PULSE_DRY_RUN=true "$PULSE_CTL" react 2>&1)"
rc=$?
assert_exit "react via dry-run returns 0" "0" "$rc"
assert_contains "react reports posted emoji" "posted" "$output"

count="$(awk -F'=' '$1=="pulse_count" {print $2}' "$SANDBOX/discord-pulse/state")"
assert_eq "pulse_count incremented to 1" "1" "$count"

# Check tier_cursor advanced after exactly one pulse — checking after 3
# pulses on a 3-item list would wrap back to 0 and confuse the assertion.
cursor="$(awk -F'=' '$1=="tier_cursor" {print $2}' "$SANDBOX/discord-pulse/state")"
assert_eq "tier_cursor advanced to 1 after first react" "1" "$cursor"

PULSE_DRY_RUN=true "$PULSE_CTL" react >/dev/null 2>&1
PULSE_DRY_RUN=true "$PULSE_CTL" react >/dev/null 2>&1
count="$(awk -F'=' '$1=="pulse_count" {print $2}' "$SANDBOX/discord-pulse/state")"
assert_eq "pulse_count incremented to 3" "3" "$count"

# Override emoji
output="$(PULSE_DRY_RUN=true "$PULSE_CTL" react --emoji '🦀' 2>&1)"
assert_contains "react --emoji uses override" "🦀" "$output"

# react without target should fail
"$PULSE_CTL" target 0 0 >/dev/null 2>&1 || true
# Re-init to clear target
rm -f "$SANDBOX/discord-pulse/state"
"$PULSE_CTL" init >/dev/null
PULSE_DRY_RUN=true "$PULSE_CTL" react >/dev/null 2>&1
assert_exit "react without target fails" "2" "$?"

teardown_sandbox

# ─────────────────────────────────────────────────────────────────────────
# 6. pulse.sh --once — single iteration with stubbed reactor
# ─────────────────────────────────────────────────────────────────────────
section "pulse.sh --once"

setup_sandbox
"$PULSE_CTL" init >/dev/null
"$PULSE_CTL" target 555 666 >/dev/null
"$PULSE_CTL" tag feat >/dev/null
"$PULSE_CTL" progress 80 >/dev/null

"$PULSE" --once
assert_exit "pulse.sh --once exits 0" "0" "$?"

# Stub reactor should have logged exactly one call
stub_calls="$(wc -l <"$STUB_LOG" | tr -d ' ')"
assert_eq "stub reactor was called once" "1" "$stub_calls"

# Stub log should include channel/message
stub_line="$(cat "$STUB_LOG")"
assert_contains "stub call has add command" "add 555 666" "$stub_line"

# State should reflect the pulse
count="$(awk -F'=' '$1=="pulse_count" {print $2}' "$SANDBOX/discord-pulse/state")"
assert_eq "--once incremented pulse_count to 1" "1" "$count"
last_emoji="$(awk -F'=' '$1=="last_emoji" {print $2}' "$SANDBOX/discord-pulse/state")"
[ -n "$last_emoji" ]
assert_exit "last_emoji recorded" "0" "$?"

# Log should have a PULSE entry for the crunching band
log="$(cat "$SANDBOX/discord-pulse/pulse.log")"
assert_contains "log shows PULSE" "PULSE" "$log"
assert_contains "log shows crunching band" "band=crunching" "$log"

teardown_sandbox

# ─────────────────────────────────────────────────────────────────────────
# 7. pulse.sh --once with no target — NO_TARGET log entry, no crash
# ─────────────────────────────────────────────────────────────────────────
section "pulse.sh --once without target"

setup_sandbox
"$PULSE_CTL" init >/dev/null
"$PULSE_CTL" progress 50 >/dev/null

"$PULSE" --once
assert_exit "pulse.sh --once with no target exits 0" "0" "$?"

stub_calls="$(wc -l <"$STUB_LOG" | tr -d ' ')"
assert_eq "stub reactor NOT called when target unset" "0" "$stub_calls"

log="$(cat "$SANDBOX/discord-pulse/pulse.log")"
assert_contains "log shows NO_TARGET" "NO_TARGET" "$log"

teardown_sandbox

# ─────────────────────────────────────────────────────────────────────────
# 8. pulse.sh --no-react — exercises pipeline without firing
# ─────────────────────────────────────────────────────────────────────────
section "pulse.sh --no-react"

setup_sandbox
"$PULSE_CTL" init >/dev/null
"$PULSE_CTL" target 1 2 >/dev/null
"$PULSE_CTL" progress 10 >/dev/null

"$PULSE" --once --no-react
assert_exit "--no-react exits 0" "0" "$?"

stub_calls="$(wc -l <"$STUB_LOG" | tr -d ' ')"
assert_eq "--no-react does not call reactor" "0" "$stub_calls"

log="$(cat "$SANDBOX/discord-pulse/pulse.log")"
assert_contains "--no-react logs PULSE_DRY" "PULSE_DRY" "$log"

teardown_sandbox

# ─────────────────────────────────────────────────────────────────────────
# 9. log rotation
# ─────────────────────────────────────────────────────────────────────────
section "log rotation"

setup_sandbox
"$PULSE_CTL" init >/dev/null
log_path="$SANDBOX/discord-pulse/pulse.log"
mkdir -p "$SANDBOX/discord-pulse"
# Pre-fill with 600 dummy lines
i=0
while [ "$i" -lt 600 ]; do
    printf 'dummy line %d\n' "$i" >>"$log_path"
    i=$((i + 1))
done

# Trigger one pulse to invoke rotation
"$PULSE_CTL" progress 5 >/dev/null  # state-only, no rotation yet
"$PULSE" --once --no-react

lines="$(wc -l <"$log_path" | tr -d ' ')"
# After rotation: 250 kept + the new dummy/log lines we added
if [ "$lines" -le 260 ]; then
    assert_eq "log rotated to ~250 lines" "1" "1"
else
    assert_eq "log rotated to ~250 lines (got $lines)" "1" "0"
fi

teardown_sandbox

# ─────────────────────────────────────────────────────────────────────────
# 10. End-to-end: progress climbs, intervals shrink
# ─────────────────────────────────────────────────────────────────────────
section "end-to-end progress acceleration"

setup_sandbox
"$PULSE_CTL" init >/dev/null
"$PULSE_CTL" target 1 1 >/dev/null

prev_interval=999999
acceleration_ok=1
for p in 0 20 40 60 80 100; do
    "$PULSE_CTL" progress "$p" >/dev/null
    out="$("$PULSE_CTL" preview 2>&1)"
    cur="$(printf '%s\n' "$out" | awk '/next interval/ { gsub(/s/, ""); print $3 }')"
    case "$cur" in
        ''|*[!0-9]*)
            acceleration_ok=0
            break
            ;;
    esac
    if [ "$cur" -gt "$prev_interval" ]; then
        acceleration_ok=0
        break
    fi
    prev_interval="$cur"
done
assert_eq "preview interval shrinks as progress climbs" "1" "$acceleration_ok"

teardown_sandbox

# ─────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────
echo
total=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
    printf '%s %d/%d tests passed\n' "$(green ✓)" "$PASS" "$total"
    exit 0
else
    printf '%s %d/%d tests passed\n' "$(red ✗)" "$PASS" "$total"
    printf 'failed:%b\n' "$FAILED_TESTS"
    exit 1
fi
