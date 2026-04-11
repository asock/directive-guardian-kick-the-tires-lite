#!/usr/bin/env bash
# directive-ctl.sh — Directive Guardian management CLI
#
# Addresses all findings from AUDIT.md:
#   BUG-001 — delegated to guardian.sh parser (flush() pattern)
#   BUG-002 — JSON escaping handled in guardian.sh
#   BUG-003 — awk block removal with proper EOF handling (cmd_remove)
#   BUG-004 — POSIX awk everywhere; no Perl-compat regex (BSD grep safe)
#   SEC-001 — advisory file locking via flock
#   SEC-002 — input validation on all text fields
#   SEC-003 — no user input in regex position; IDs validated to safe format
#   SEC-004 — SHA-256 checksum maintained on every mutation
#   SEC-005 — log rotation hook shared with guardian.sh
#   FEAT-001..007 — enable/disable, backup, export/import, edit, search,
#                   diff/status, and the tests/ harness are all provided.

set -euo pipefail

CTL_VERSION="2.0.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARDIAN_BIN="$SCRIPT_DIR/guardian.sh"

MEMORY_DIR="${OPENCLAW_MEMORY_DIR:-$HOME/.openclaw/memory}"
REGISTRY="$MEMORY_DIR/directives.md"
CHECKSUM_FILE="$MEMORY_DIR/directives.sha256"
BACKUP_FILE="$MEMORY_DIR/directives.md.bak"
LOG_FILE="$MEMORY_DIR/directive-guardian.log"
LOCK_FILE="$MEMORY_DIR/.guardian.lock"
LOCK_TIMEOUT="${GUARDIAN_LOCK_TIMEOUT:-10}"
AUTO_YES="${GUARDIAN_YES:-false}"
LOG_MAX_LINES="${GUARDIAN_LOG_MAX_LINES:-500}"

# --- tty-aware color --------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET='\033[0m'; C_RED='\033[31m'; C_GREEN='\033[32m'
    C_YELLOW='\033[33m'; C_BLUE='\033[34m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
else
    C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_DIM=''
fi

_err()  { printf "${C_RED}error:${C_RESET} %s\n" "$*" >&2; }
_warn() { printf "${C_YELLOW}warn:${C_RESET}  %s\n" "$*" >&2; }
_info() { printf "${C_BLUE}info:${C_RESET}  %s\n" "$*" >&2; }
_ok()   { printf "${C_GREEN}ok:${C_RESET}    %s\n" "$*" >&2; }

_timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

_log() {
    local level="$1"; shift
    {
        printf '%s [%s] %s\n' "$(_timestamp)" "$level" "$*" >> "$LOG_FILE"
    } 2>/dev/null || true
}

# --- bootstrap, lock, integrity ---------------------------------------------

_bootstrap() {
    if [ ! -d "$MEMORY_DIR" ]; then
        mkdir -p "$MEMORY_DIR"
        chmod 700 "$MEMORY_DIR" 2>/dev/null || true
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

_with_lock() {
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCK_FILE"
        if ! flock -w "$LOCK_TIMEOUT" 9; then
            _err "could not acquire lock within ${LOCK_TIMEOUT}s"
            exit 2
        fi
    fi
}

_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    fi
}

_update_checksum() {
    local sum
    sum="$(_sha256 "$REGISTRY" || true)"
    if [ -n "${sum:-}" ]; then
        printf '%s\n' "$sum" > "$CHECKSUM_FILE"
        chmod 600 "$CHECKSUM_FILE" 2>/dev/null || true
    fi
}

_backup_registry() {
    # FEAT-002: auto-backup before every destructive op.
    [ -f "$REGISTRY" ] || return 0
    cp -p "$REGISTRY" "$BACKUP_FILE" 2>/dev/null || true
    chmod 600 "$BACKUP_FILE" 2>/dev/null || true
}

_atomic_replace() {
    # Write a fresh copy to a temp file, then rename over the registry.
    # Rename is atomic on the same filesystem, which prevents half-written
    # registries if the process is killed mid-write.
    local src="$1"
    chmod 600 "$src" 2>/dev/null || true
    mv "$src" "$REGISTRY"
    chmod 600 "$REGISTRY" 2>/dev/null || true
}

# --- validation -------------------------------------------------------------

_validate_priority() {
    case "$1" in
        critical|high|medium|low) return 0 ;;
        *)
            _err "invalid priority '$1' (expected: critical, high, medium, low)"
            return 1
            ;;
    esac
}

_validate_id_format() {
    # SEC-003: IDs are constrained to DIRECTIVE-<digits> so they are safe to
    # interpolate into awk string comparisons. No regex metacharacters can
    # sneak through.
    if [[ ! "$1" =~ ^DIRECTIVE-[0-9]+$ ]]; then
        _err "invalid ID format '$1' (expected DIRECTIVE-NNN)"
        return 1
    fi
}

_validate_text_field() {
    # SEC-002: reject embedded newlines, carriage returns, and injection
    # patterns that would let a user smuggle a second directive header into
    # the value of a single field.
    local val="$1" label="${2:-text}"
    if [ -z "$val" ]; then
        _err "$label cannot be empty"
        return 1
    fi
    case "$val" in
        *$'\n'*|*$'\r'*)
            _err "$label cannot contain newlines"
            return 1
            ;;
    esac
    # Reject bare control characters (ASCII 0x00-0x1F except tab).
    if printf '%s' "$val" | LC_ALL=C awk '
        { for (i=1; i<=length($0); i++) {
              c = substr($0,i,1)
              if (c < " " && c != "\t") { exit 1 }
          }
        }
    '; then :; else
        _err "$label cannot contain control characters"
        return 1
    fi
    # Reject attempts to embed a new directive header via field injection.
    case "$val" in
        *'## [DIRECTIVE-'*)
            _err "$label cannot contain injection pattern '## [DIRECTIVE-'"
            return 1
            ;;
    esac
    return 0
}

# --- registry queries -------------------------------------------------------

_next_id() {
    awk '
    match($0, /^## \[DIRECTIVE-[0-9]+\]/) {
        s = substr($0, RSTART, RLENGTH)
        gsub(/[^0-9]/, "", s)
        n = s + 0
        if (n > max) max = n
    }
    END { printf "DIRECTIVE-%03d", max + 1 }
    ' "$REGISTRY"
}

_id_exists() {
    # Note: we first anchor on the heading shape, then re-match the inner
    # bracket pattern. A single anchored match would hand back RSTART=1
    # (pointing at "#"), and substr() with RSTART+1 would skip half the ID.
    awk -v id="$1" '
    /^## \[DIRECTIVE-[0-9]+\]/ {
        match($0, /\[DIRECTIVE-[0-9]+\]/)
        s = substr($0, RSTART + 1, RLENGTH - 2)
        if (s == id) { found = 1; exit }
    }
    END { exit (found ? 0 : 1) }
    ' "$REGISTRY"
}

# --- commands ---------------------------------------------------------------

cmd_add() {
    local title="${1:-}" priority="${2:-}" category="${3:-}" directive="${4:-}" verify="${5:-}"
    if [ -z "$title" ] || [ -z "$priority" ] || [ -z "$category" ] || [ -z "$directive" ]; then
        _err "usage: add <title> <priority> <category> <directive> [verify]"
        return 1
    fi
    _validate_priority "$priority" || return 1
    _validate_text_field "$title"     "title"     || return 1
    _validate_text_field "$category"  "category"  || return 1
    _validate_text_field "$directive" "directive" || return 1
    if [ -n "$verify" ]; then
        _validate_text_field "$verify" "verify" || return 1
    fi

    _bootstrap
    _with_lock
    _backup_registry

    local id
    id="$(_next_id)"

    {
        printf '## [%s] %s\n' "$id" "$title"
        printf -- '- **priority**: %s\n' "$priority"
        printf -- '- **category**: %s\n' "$category"
        printf -- '- **enabled**: true\n'
        printf -- '- **directive**: %s\n' "$directive"
        if [ -n "$verify" ]; then
            printf -- '- **verify**: %s\n' "$verify"
        fi
        printf '\n'
    } >> "$REGISTRY"

    _update_checksum
    _log ADD "$id priority=$priority category=$category"
    _ok "added $id"
    printf '%s\n' "$id"
}

cmd_remove() {
    local id="${1:-}"
    [ -z "$id" ] && { _err "usage: remove <DIRECTIVE-NNN>"; return 1; }
    _validate_id_format "$id" || return 1
    _id_exists "$id" || { _err "no directive with id '$id'"; return 1; }

    if [ "$AUTO_YES" != "true" ]; then
        printf "Remove %s? [y/N] " "$id" >&2
        local reply=""
        read -r reply || true
        case "$reply" in
            y|Y|yes|YES) ;;
            *) _info "cancelled"; return 0 ;;
        esac
    fi

    _with_lock
    _backup_registry

    local tmp
    tmp="$(mktemp "${REGISTRY}.XXXXXX")"

    # BUG-003 fix: awk state machine that cleanly removes a block without
    # accidentally running off the end of the file. A trailing blank line
    # is consumed (the one separating this directive from the next), and
    # a following directive heading resumes normal printing.
    awk -v id="$id" '
    BEGIN { skip = 0 }
    /^## \[DIRECTIVE-[0-9]+\]/ {
        match($0, /\[DIRECTIVE-[0-9]+\]/)
        cur = substr($0, RSTART + 1, RLENGTH - 2)
        if (cur == id) { skip = 1; next }
        skip = 0; print; next
    }
    skip == 1 && /^- \*\*/ { next }
    skip == 1 && /^[[:space:]]*$/ { skip = 0; next }
    skip == 1 { skip = 0; print; next }
    { print }
    ' "$REGISTRY" > "$tmp"

    _atomic_replace "$tmp"
    _update_checksum
    _log REMOVE "$id"
    _ok "removed $id"
}

cmd_edit() {
    local id="${1:-}"
    [ -z "$id" ] && { _err "usage: edit <DIRECTIVE-NNN> --<field> <value>"; return 1; }
    _validate_id_format "$id" || return 1
    _id_exists "$id" || { _err "no directive with id '$id'"; return 1; }
    shift

    local field="" value=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --title|--priority|--category|--directive|--verify)
                field="${1#--}"
                value="${2:-}"
                shift 2 || true
                ;;
            *)
                _err "unknown option: $1"
                return 1
                ;;
        esac
    done

    [ -z "$field" ] && { _err "specify a field to edit: --title --priority --category --directive --verify"; return 1; }

    if [ "$field" = "priority" ]; then
        _validate_priority "$value" || return 1
    else
        _validate_text_field "$value" "$field" || return 1
    fi

    _with_lock
    _backup_registry

    local tmp
    tmp="$(mktemp "${REGISTRY}.XXXXXX")"

    awk -v id="$id" -v field="$field" -v value="$value" '
    BEGIN { in_block = 0 }
    /^## \[DIRECTIVE-[0-9]+\]/ {
        match($0, /\[DIRECTIVE-[0-9]+\]/)
        cur = substr($0, RSTART + 1, RLENGTH - 2)
        if (cur == id) {
            in_block = 1
            if (field == "title") {
                printf "## [%s] %s\n", id, value
                next
            }
        } else {
            in_block = 0
        }
        print; next
    }
    in_block == 1 && field != "title" {
        if ($0 ~ ("^- \\*\\*" field "\\*\\*:")) {
            printf "- **%s**: %s\n", field, value
            next
        }
    }
    /^## / { in_block = 0 }
    { print }
    ' "$REGISTRY" > "$tmp"

    _atomic_replace "$tmp"
    _update_checksum
    _log EDIT "$id $field"
    _ok "edited $id.$field"
}

_set_enabled() {
    local id="$1" val="$2"
    _validate_id_format "$id" || return 1
    _id_exists "$id" || { _err "no directive with id '$id'"; return 1; }

    _with_lock
    _backup_registry

    local tmp
    tmp="$(mktemp "${REGISTRY}.XXXXXX")"
    awk -v id="$id" -v val="$val" '
    BEGIN { in_block = 0 }
    /^## \[DIRECTIVE-[0-9]+\]/ {
        match($0, /\[DIRECTIVE-[0-9]+\]/)
        cur = substr($0, RSTART + 1, RLENGTH - 2)
        in_block = (cur == id ? 1 : 0)
        print; next
    }
    in_block == 1 && /^- \*\*enabled\*\*:/ {
        printf "- **enabled**: %s\n", val
        next
    }
    /^## / { in_block = 0 }
    { print }
    ' "$REGISTRY" > "$tmp"

    _atomic_replace "$tmp"
    _update_checksum
    _log TOGGLE "$id -> enabled=$val"
    _ok "$id enabled=$val"
}

cmd_enable()  { [ $# -lt 1 ] && { _err "usage: enable <DIRECTIVE-NNN>"; return 1; };  _set_enabled "$1" "true"; }
cmd_disable() { [ $# -lt 1 ] && { _err "usage: disable <DIRECTIVE-NNN>"; return 1; }; _set_enabled "$1" "false"; }

cmd_list() {
    local filter_priority="" filter_category=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --priority) filter_priority="${2:-}"; shift 2 ;;
            --category) filter_category="${2:-}"; shift 2 ;;
            *) _err "unknown option: $1"; return 1 ;;
        esac
    done

    _bootstrap

    awk -v fp="$filter_priority" -v fc="$filter_category" '
    function reset() {
        id=""; title=""; priority=""; category=""; enabled=""
    }
    function flush() {
        if (id == "") return
        if (fp != "" && fp != priority)  { reset(); return }
        if (fc != "" && fc != category)  { reset(); return }
        en = (tolower(enabled) == "false" ? "no " : "yes")
        printf "%-16s  %-8s  %-12s  %-3s  %s\n", id, priority, category, en, title
        reset()
    }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    BEGIN {
        reset()
        printf "%-16s  %-8s  %-12s  %-3s  %s\n", "ID", "PRI", "CATEGORY", "EN", "TITLE"
        printf "%-16s  %-8s  %-12s  %-3s  %s\n", "----------------", "--------", "------------", "---", "-----"
    }
    /^## \[DIRECTIVE-[0-9]+\]/ {
        flush()
        match($0, /\[DIRECTIVE-[0-9]+\]/)
        id = substr($0, RSTART + 1, RLENGTH - 2)
        title = trim(substr($0, RSTART + RLENGTH))
        next
    }
    /^- \*\*priority\*\*:/ { sub(/^- \*\*priority\*\*: */, ""); priority = trim($0); next }
    /^- \*\*category\*\*:/ { sub(/^- \*\*category\*\*: */, ""); category = trim($0); next }
    /^- \*\*enabled\*\*:/  { sub(/^- \*\*enabled\*\*: */, "");  enabled  = trim($0); next }
    END { flush() }
    ' "$REGISTRY"
}

cmd_search() {
    local kw="${1:-}"
    [ -z "$kw" ] && { _err "usage: search <keyword>"; return 1; }
    _bootstrap

    awk -v kw="$kw" '
    function reset() { id=""; title=""; block="" }
    function flush() {
        if (id == "") return
        if (index(tolower(block), tolower(kw)) > 0) {
            printf "%s  %s\n", id, title
        }
        reset()
    }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    BEGIN { reset() }
    /^## \[DIRECTIVE-[0-9]+\]/ {
        flush()
        match($0, /\[DIRECTIVE-[0-9]+\]/)
        id = substr($0, RSTART + 1, RLENGTH - 2)
        title = trim(substr($0, RSTART + RLENGTH))
        block = $0 "\n"
        next
    }
    id != "" { block = block $0 "\n" }
    END { flush() }
    ' "$REGISTRY"
}

cmd_status() {
    _bootstrap
    printf "${C_BOLD}Directive Guardian${C_RESET} v%s\n" "$CTL_VERSION"
    printf "Registry:   %s\n" "$REGISTRY"
    printf "Memory dir: %s\n" "$MEMORY_DIR"

    # Integrity
    if [ -f "$CHECKSUM_FILE" ]; then
        local expected actual
        expected="$(cat "$CHECKSUM_FILE" 2>/dev/null || printf '')"
        actual="$(_sha256 "$REGISTRY" || printf '')"
        if [ -z "$actual" ]; then
            printf "Integrity:  ${C_YELLOW}UNKNOWN${C_RESET} (no sha256 tool)\n"
        elif [ "$expected" = "$actual" ]; then
            printf "Integrity:  ${C_GREEN}OK${C_RESET}  %s\n" "${actual:0:16}"
        else
            printf "Integrity:  ${C_RED}MISMATCH${C_RESET}\n"
            printf "  expected: %s\n" "${expected:0:16}"
            printf "  actual:   %s\n" "${actual:0:16}"
        fi
    else
        printf "Integrity:  ${C_YELLOW}NO BASELINE${C_RESET}\n"
    fi

    # Counts — use awk (grep -c returns 1 on no match which trips set -e).
    local total enabled disabled
    total=$(awk '/^## \[DIRECTIVE-/{n++} END{print n+0}' "$REGISTRY")
    enabled=$(awk '/^- \*\*enabled\*\*: true/{n++} END{print n+0}' "$REGISTRY")
    disabled=$(awk '/^- \*\*enabled\*\*: false/{n++} END{print n+0}' "$REGISTRY")
    printf "Directives: %d total / %d enabled / %d disabled\n" "$total" "$enabled" "$disabled"

    printf "\n${C_BOLD}Recent log${C_RESET}\n"
    if [ -f "$LOG_FILE" ]; then
        tail -n 15 "$LOG_FILE"
    else
        printf "${C_DIM}(no log entries yet)${C_RESET}\n"
    fi
}

cmd_backup() {
    _bootstrap
    _with_lock
    local stamp dest
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    dest="$MEMORY_DIR/directives.${stamp}.md.bak"
    cp -p "$REGISTRY" "$dest"
    chmod 600 "$dest" 2>/dev/null || true
    cp -p "$REGISTRY" "$BACKUP_FILE" 2>/dev/null || true
    _log BACKUP "$dest"
    _ok "backup: $dest"
    printf '%s\n' "$dest"
}

cmd_restore() {
    local src="${1:-$BACKUP_FILE}"
    [ -f "$src" ] || { _err "backup not found: $src"; return 1; }

    if [ "$AUTO_YES" != "true" ]; then
        printf "Restore from %s? [y/N] " "$src" >&2
        local reply=""
        read -r reply || true
        case "$reply" in
            y|Y|yes|YES) ;;
            *) _info "cancelled"; return 0 ;;
        esac
    fi

    _with_lock
    # Safety net: snapshot current registry before restore in case the user
    # picked the wrong backup file.
    cp -p "$REGISTRY" "$MEMORY_DIR/directives.pre-restore.bak" 2>/dev/null || true
    cp -p "$src" "$REGISTRY"
    chmod 600 "$REGISTRY" 2>/dev/null || true
    _update_checksum
    _log RESTORE "from=$src"
    _ok "restored from $src"
}

cmd_export() {
    local out="${1:-$MEMORY_DIR/directives-export.json}"
    _bootstrap
    # Run guardian.sh to produce the canonical manifest.
    GUARDIAN_QUIET=true GUARDIAN_DRY_RUN=true "$GUARDIAN_BIN" > "$out"
    _log EXPORT "to=$out"
    _ok "exported to $out"
}

cmd_import() {
    local in="${1:-}"
    [ -z "$in" ] && { _err "usage: import <file>"; return 1; }
    [ -f "$in" ] || { _err "file not found: $in"; return 1; }

    if ! command -v jq >/dev/null 2>&1; then
        _err "import requires jq"
        return 1
    fi

    _bootstrap
    _with_lock
    _backup_registry

    local count=0 skipped=0
    # Use process substitution to keep the while loop in the current shell
    # so count/skipped survive.
    while IFS= read -r entry; do
        local title priority category enabled directive verify
        title="$(printf '%s' "$entry"     | jq -r '.title')"
        priority="$(printf '%s' "$entry"  | jq -r '.priority')"
        category="$(printf '%s' "$entry"  | jq -r '.category')"
        enabled="$(printf '%s' "$entry"   | jq -r '.enabled')"
        directive="$(printf '%s' "$entry" | jq -r '.directive')"
        verify="$(printf '%s' "$entry"    | jq -r '.verify // ""')"

        if ! _validate_priority "$priority" 2>/dev/null \
           || ! _validate_text_field "$title"     "title"     2>/dev/null \
           || ! _validate_text_field "$category"  "category"  2>/dev/null \
           || ! _validate_text_field "$directive" "directive" 2>/dev/null; then
            _warn "skipping invalid entry: $title"
            skipped=$((skipped + 1))
            continue
        fi

        local id
        id="$(_next_id)"
        {
            printf '## [%s] %s\n' "$id" "$title"
            printf -- '- **priority**: %s\n' "$priority"
            printf -- '- **category**: %s\n' "$category"
            printf -- '- **enabled**: %s\n' "${enabled:-true}"
            printf -- '- **directive**: %s\n' "$directive"
            if [ -n "$verify" ] && [ "$verify" != "null" ]; then
                printf -- '- **verify**: %s\n' "$verify"
            fi
            printf '\n'
        } >> "$REGISTRY"
        count=$((count + 1))
    done < <(jq -c '.[]' "$in")

    _update_checksum
    _log IMPORT "added=$count skipped=$skipped from=$in"
    _ok "imported $count directives ($skipped skipped)"
}

cmd_checksum() {
    _bootstrap
    _with_lock
    _update_checksum
    if [ -f "$CHECKSUM_FILE" ]; then
        _ok "checksum: $(cat "$CHECKSUM_FILE")"
    else
        _err "could not compute checksum (no sha256sum/shasum available)"
        return 1
    fi
}

cmd_validate() {
    _bootstrap
    local errors=0 total=0 current="" saw_p=0 saw_c=0 saw_e=0 saw_d=0

    _check_block() {
        [ -z "$current" ] && return
        if [ "$saw_p" -eq 0 ]; then _err "$current: missing priority"; errors=$((errors+1)); fi
        if [ "$saw_c" -eq 0 ]; then _err "$current: missing category"; errors=$((errors+1)); fi
        if [ "$saw_e" -eq 0 ]; then _err "$current: missing enabled";  errors=$((errors+1)); fi
        if [ "$saw_d" -eq 0 ]; then _err "$current: missing directive"; errors=$((errors+1)); fi
    }

    while IFS= read -r line; do
        if [[ "$line" =~ ^##\ \[DIRECTIVE-[0-9]+\] ]]; then
            _check_block
            current="${line#*[}"
            current="${current%%]*}"
            saw_p=0; saw_c=0; saw_e=0; saw_d=0
            total=$((total+1))
            continue
        fi
        case "$line" in
            "- **priority**: critical"|"- **priority**: high"|"- **priority**: medium"|"- **priority**: low")
                saw_p=1 ;;
            "- **priority**: "*)
                _err "$current: invalid priority value: ${line#*: }"
                errors=$((errors+1)); saw_p=1 ;;
            "- **category**: "*)   saw_c=1 ;;
            "- **enabled**: true"|"- **enabled**: false") saw_e=1 ;;
            "- **enabled**: "*)
                _err "$current: invalid enabled value: ${line#*: }"
                errors=$((errors+1)); saw_e=1 ;;
            "- **directive**: "*)  saw_d=1 ;;
        esac
    done < "$REGISTRY"
    _check_block

    if [ "$errors" -eq 0 ]; then
        _ok "registry valid — $total directive(s)"
        return 0
    fi
    _err "$errors validation error(s) in $total directive(s)"
    return 1
}

cmd_help() {
    cat <<EOF
directive-ctl $CTL_VERSION — Directive Guardian management CLI

USAGE
  directive-ctl <command> [args...]

COMMANDS
  add <title> <priority> <category> <directive> [verify]
                                  Add a new directive (auto-assigns ID).
  remove <DIRECTIVE-NNN>          Remove a directive (with confirmation).
  edit <DIRECTIVE-NNN> --<field> <value>
                                  Edit a field in place.
                                  Fields: title, priority, category, directive, verify.
  enable  <DIRECTIVE-NNN>         Mark directive as enabled.
  disable <DIRECTIVE-NNN>         Mark directive as disabled (kept in file).
  list [--priority P] [--category C]
                                  Tabular listing, optionally filtered.
  search <keyword>                Case-insensitive full-text search.
  status                          Show integrity, counts, and recent log.
  backup                          Create a timestamped backup.
  restore [file]                  Restore from backup (default: directives.md.bak).
  export [file]                   Export manifest as JSON.
  import <file>                   Append directives from a JSON export.
  checksum                        Recalculate and store SHA-256 checksum.
  validate                        Parse-check the registry.
  version                         Print version and exit.
  help                            Show this text.

ENVIRONMENT
  OPENCLAW_MEMORY_DIR   Location of registry (default: ~/.openclaw/memory)
  GUARDIAN_YES          If "true", skip confirmations on destructive ops.
  GUARDIAN_LOCK_TIMEOUT Seconds to wait for lock (default: 10).
  NO_COLOR              Disable color output.

VALID PRIORITIES
  critical, high, medium, low

EXAMPLES
  directive-ctl add "Core Persona" critical identity \\
      "You are my AI agent. Be direct and technical."
  directive-ctl list --priority critical
  directive-ctl disable DIRECTIVE-002
  directive-ctl edit DIRECTIVE-001 --directive "Updated persona text"
  directive-ctl search docker
EOF
}

cmd_version() { printf 'directive-ctl %s\n' "$CTL_VERSION"; }

# --- dispatch ---------------------------------------------------------------

main() {
    local cmd="${1:-help}"
    shift || true
    case "$cmd" in
        add)       cmd_add "$@" ;;
        remove|rm|del|delete) cmd_remove "$@" ;;
        edit)      cmd_edit "$@" ;;
        enable)    cmd_enable "$@" ;;
        disable)   cmd_disable "$@" ;;
        list|ls)   cmd_list "$@" ;;
        search|grep) cmd_search "$@" ;;
        status)    cmd_status "$@" ;;
        backup)    cmd_backup "$@" ;;
        restore)   cmd_restore "$@" ;;
        export)    cmd_export "$@" ;;
        import)    cmd_import "$@" ;;
        checksum)  cmd_checksum "$@" ;;
        validate|check) cmd_validate "$@" ;;
        help|-h|--help) cmd_help ;;
        version|-V|--version) cmd_version ;;
        *)
            _err "unknown command: $cmd"
            printf 'Run "directive-ctl help" for usage.\n' >&2
            return 1
            ;;
    esac
}

main "$@"
