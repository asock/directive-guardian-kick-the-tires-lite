#!/usr/bin/env bash
# guardian.sh — Directive Guardian boot script
#
# Parses the directive registry, verifies integrity, sorts by priority, and
# emits a JSON manifest on stdout for the agent to re-apply. All side effects
# (logs, checksum updates) go through advisory file locking to prevent the
# cron-vs-user race described in SEC-001.
#
# Exit codes:
#   0  success
#   1  runtime error (missing tools, filesystem errors)
#   2  lock acquisition timeout
#   3  integrity failure (only in GUARDIAN_STRICT=true mode)

set -euo pipefail

GUARDIAN_VERSION="2.0.0"

# --- configuration ----------------------------------------------------------

MEMORY_DIR="${OPENCLAW_MEMORY_DIR:-$HOME/.openclaw/memory}"
REGISTRY="$MEMORY_DIR/directives.md"
CHECKSUM_FILE="$MEMORY_DIR/directives.sha256"
LOG_FILE="$MEMORY_DIR/directive-guardian.log"
LOCK_FILE="$MEMORY_DIR/.guardian.lock"

LOG_MAX_LINES="${GUARDIAN_LOG_MAX_LINES:-500}"
LOCK_TIMEOUT="${GUARDIAN_LOCK_TIMEOUT:-10}"
DRY_RUN="${GUARDIAN_DRY_RUN:-false}"
STRICT="${GUARDIAN_STRICT:-false}"
QUIET="${GUARDIAN_QUIET:-false}"

# --- utilities --------------------------------------------------------------

_timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

_log() {
    # Append to log file. Never fails the script — logging is best-effort.
    local level="$1"; shift
    {
        printf '%s [%s] %s\n' "$(_timestamp)" "$level" "$*" >> "$LOG_FILE"
    } 2>/dev/null || true
}

_warn() {
    [ "$QUIET" = "true" ] && return 0
    printf 'guardian: %s\n' "$*" >&2
}

_rotate_log() {
    # SEC-005 fix: bounded log size.
    [ -f "$LOG_FILE" ] || return 0
    local lines
    lines=$(awk 'END{print NR+0}' "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "${lines:-0}" -gt "$LOG_MAX_LINES" ]; then
        local tmp
        tmp="$(mktemp "${LOG_FILE}.XXXXXX")" || return 0
        tail -n "$LOG_MAX_LINES" "$LOG_FILE" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
        mv "$tmp" "$LOG_FILE"
        chmod 600 "$LOG_FILE" 2>/dev/null || true
    fi
}

_sha256() {
    # Portable SHA-256. sha256sum on Linux, shasum on BSD/macOS.
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    else
        return 1
    fi
}

_bootstrap() {
    if [ ! -d "$MEMORY_DIR" ]; then
        mkdir -p "$MEMORY_DIR"
        chmod 700 "$MEMORY_DIR" 2>/dev/null || true
        _log BOOTSTRAP "Created memory dir: $MEMORY_DIR"
    fi
    if [ ! -f "$REGISTRY" ]; then
        cat > "$REGISTRY" <<'EOF'
# Directive Registry
<!--
Managed by Directive Guardian.
Do not edit directive IDs manually. Use `directive-ctl` for changes.
-->

EOF
        chmod 600 "$REGISTRY" 2>/dev/null || true
        _log BOOTSTRAP "Created empty registry: $REGISTRY"
    fi
}

_verify_integrity() {
    # SEC-004: detect unauthorized modifications.
    if [ ! -f "$CHECKSUM_FILE" ]; then
        _log INTEGRITY_INIT "No baseline checksum; one will be written after parse"
        return 0
    fi
    local expected actual
    expected="$(cat "$CHECKSUM_FILE" 2>/dev/null || printf '')"
    actual="$(_sha256 "$REGISTRY" 2>/dev/null || printf '')"
    if [ -z "$actual" ]; then
        _log INTEGRITY_WARN "Could not compute SHA-256 (no sha256sum/shasum)"
        return 0
    fi
    if [ "$expected" != "$actual" ]; then
        _log INTEGRITY_MISMATCH "expected=$expected actual=$actual"
        _warn "integrity mismatch — registry changed outside directive-ctl"
        if [ "$STRICT" = "true" ]; then
            return 3
        fi
    fi
    return 0
}

_update_checksum() {
    [ "$DRY_RUN" = "true" ] && return 0
    local sum
    sum="$(_sha256 "$REGISTRY" 2>/dev/null || printf '')"
    if [ -n "$sum" ]; then
        printf '%s\n' "$sum" > "$CHECKSUM_FILE"
        chmod 600 "$CHECKSUM_FILE" 2>/dev/null || true
    fi
}

# --- parser -----------------------------------------------------------------
#
# BUG-001 fix: use a flush() function that emits the buffered directive the
# moment we see a new heading, rather than waiting for a blank line. This
# correctly handles back-to-back directives and directives separated by
# arbitrary non-field lines.
#
# BUG-002 fix: json_escape() handles the full set of JSON-illegal characters
# for single-line field values: backslash, double-quote, and the five
# C-escapes. Bare control characters cannot appear in our registry format
# because each field is written on a single line by directive-ctl (which also
# rejects them at input time), so we do not need \u00XX escapes here.

_parse_to_json() {
    awk '
    function reset() {
        id=""; title=""; priority=""; category=""
        enabled=""; directive=""; verify=""
    }
    function json_escape(s,    out, i, n, c) {
        out = ""
        n = length(s)
        for (i = 1; i <= n; i++) {
            c = substr(s, i, 1)
            if      (c == "\\") out = out "\\\\"
            else if (c == "\"") out = out "\\\""
            else if (c == "\b") out = out "\\b"
            else if (c == "\f") out = out "\\f"
            else if (c == "\n") out = out "\\n"
            else if (c == "\r") out = out "\\r"
            else if (c == "\t") out = out "\\t"
            else                out = out c
        }
        return out
    }
    function trim(s) {
        sub(/^[ \t]+/, "", s)
        sub(/[ \t\r]+$/, "", s)
        return s
    }
    function flush() {
        if (id == "") return
        # Default enabled to true when omitted; anything other than
        # the literal string "false" (case insensitive) is treated as true.
        enbool = "true"
        el = tolower(enabled)
        if (el == "false") enbool = "false"
        if (!first) printf ","
        first = 0
        printf "{"
        printf "\"id\":\"%s\",",        json_escape(id)
        printf "\"title\":\"%s\",",     json_escape(title)
        printf "\"priority\":\"%s\",",  json_escape(priority)
        printf "\"category\":\"%s\",",  json_escape(category)
        printf "\"enabled\":%s,",       enbool
        printf "\"directive\":\"%s\",", json_escape(directive)
        printf "\"verify\":\"%s\"",     json_escape(verify)
        printf "}"
        reset()
    }
    BEGIN { first = 1; printf "["; reset() }
    /^## \[DIRECTIVE-[0-9]+\]/ {
        flush()
        match($0, /\[DIRECTIVE-[0-9]+\]/)
        id = substr($0, RSTART + 1, RLENGTH - 2)
        rest = substr($0, RSTART + RLENGTH)
        title = trim(rest)
        next
    }
    /^- \*\*priority\*\*:/  { sub(/^- \*\*priority\*\*: */, "");  priority  = trim($0); next }
    /^- \*\*category\*\*:/  { sub(/^- \*\*category\*\*: */, "");  category  = trim($0); next }
    /^- \*\*enabled\*\*:/   { sub(/^- \*\*enabled\*\*: */, "");   enabled   = trim($0); next }
    /^- \*\*directive\*\*:/ { sub(/^- \*\*directive\*\*: */, ""); directive = trim($0); next }
    /^- \*\*verify\*\*:/    { sub(/^- \*\*verify\*\*: */, "");    verify    = trim($0); next }
    END { flush(); printf "]" }
    ' "$REGISTRY"
}

# --- sort / filter ----------------------------------------------------------

_sort_and_filter() {
    local json="$1"
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$json" | jq -c '
            map(select(.enabled == true))
            | sort_by(
                if   .priority == "critical" then 0
                elif .priority == "high"     then 1
                elif .priority == "medium"   then 2
                elif .priority == "low"      then 3
                else 4 end
              )
        '
    else
        # Fallback: no jq. Preserve file order and drop disabled entries with
        # a small awk filter over the raw JSON. This is a degraded mode: we
        # cannot reorder, but we do honor enabled:false.
        printf '%s' "$json" | awk '
        BEGIN { RS="},{"; first=1 }
        {
            chunk = $0
            # Re-add braces stripped by RS for middle records.
            if (NR > 1) chunk = "{" chunk
            if (chunk !~ /}$/) chunk = chunk "}"
            # Strip leading [{ or trailing }]
            sub(/^\[\{/, "{", chunk)
            sub(/\}\]$/, "}", chunk)
            if (chunk ~ /"enabled":false/) next
            if (!first) printf ","; else printf "["
            first = 0
            printf "%s", chunk
        }
        END { if (first) printf "[]"; else printf "]" }
        '
    fi
}

# --- locking ----------------------------------------------------------------

_with_lock() {
    # SEC-001: advisory locking via flock (Linux). On macOS/BSD without flock,
    # we fall through. This is a documented degradation, not silent.
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCK_FILE"
        if ! flock -w "$LOCK_TIMEOUT" 9; then
            _log LOCK_TIMEOUT "Failed to acquire lock within ${LOCK_TIMEOUT}s"
            _warn "lock timeout after ${LOCK_TIMEOUT}s"
            return 2
        fi
    fi
    return 0
}

# --- main -------------------------------------------------------------------

main() {
    case "${1:-}" in
        --version|-V)
            printf 'directive-guardian %s\n' "$GUARDIAN_VERSION"
            return 0
            ;;
        --help|-h)
            cat <<EOF
directive-guardian $GUARDIAN_VERSION

Usage: guardian.sh [--version | --help]

Reads \$OPENCLAW_MEMORY_DIR/directives.md, verifies integrity, and prints a
priority-sorted JSON manifest of enabled directives to stdout.

Environment:
  OPENCLAW_MEMORY_DIR     default: ~/.openclaw/memory
  GUARDIAN_LOG_MAX_LINES  default: 500
  GUARDIAN_LOCK_TIMEOUT   default: 10 (seconds)
  GUARDIAN_DRY_RUN        default: false (skip checksum updates)
  GUARDIAN_STRICT         default: false (exit 3 on integrity mismatch)
  GUARDIAN_QUIET          default: false (suppress stderr warnings)
EOF
            return 0
            ;;
    esac

    _bootstrap
    _with_lock || return $?
    _rotate_log
    _verify_integrity || return $?

    local raw manifest
    raw="$(_parse_to_json)"
    manifest="$(_sort_and_filter "$raw")"
    printf '%s\n' "$manifest"

    # Summary counts for the audit log. Only accurate when jq is present;
    # otherwise we record "?" so the operator knows the degraded path ran.
    local total enabled_count
    if command -v jq >/dev/null 2>&1; then
        total="$(printf '%s' "$raw"      | jq 'length' 2>/dev/null || printf '?')"
        enabled_count="$(printf '%s' "$manifest" | jq 'length' 2>/dev/null || printf '?')"
    else
        total="?"
        enabled_count="?"
    fi
    _log AUDIT_OK "Applied $enabled_count / $total directives"

    _update_checksum
    return 0
}

main "$@"
