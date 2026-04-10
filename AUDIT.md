# DIRECTIVE-GUARDIAN v1 → v2 AUDIT REPORT
## Orbital Threat Assessment — 18 Findings

---

### 🔴 CRITICAL BUGS (4)

**BUG-001: AWK parser silently drops directives between headings**
- File: `guardian.sh` line 44-97
- The awk script uses `next` on line 57 when it matches a `## [DIRECTIVE-` 
  heading, which skips all remaining rules for that input line. But lines 
  91-97 use the SAME heading pattern to emit the *previous* directive.
  Since `next` already consumed the line, the emit block only fires on 
  blank lines (`/^$/`). If two directives are separated by non-blank 
  non-heading lines (or are back-to-back), intermediate directives vanish.
- **Impact**: Silent data loss. User thinks directives are saved; guardian 
  quietly ignores them.
- **Fix**: Restructure awk to emit the buffered directive BEFORE processing 
  the new heading, using a `flush()` function pattern.

**BUG-002: JSON injection via unescaped special characters**
- File: `guardian.sh` awk block
- Only double-quotes are escaped (`gsub(/"/, ...)`). Backslashes, newlines, 
  tabs, carriage returns, and other JSON-illegal characters are passed raw.
  A directive containing `C:\new\tools` produces invalid JSON that crashes 
  any downstream parser.
- **Impact**: Parse failure → guardian outputs malformed JSON → agent gets 
  no directives on boot.
- **Fix**: Escape `\`, `\n`, `\r`, `\t`, and control characters per RFC 8259.

**BUG-003: `sed` remove command destroys trailing content**
- File: `directive-ctl.sh` line 48
- The sed address range `/^## \[$target\]/,/^## \[DIRECTIVE-/` works for 
  middle directives, but if the target is the LAST directive in the file, 
  sed never finds the end pattern — so it deletes everything from the target 
  heading to EOF, including comments, blank lines, or any non-directive 
  content at the end.
- **Impact**: Data loss on remove of last directive.
- **Fix**: Use awk for block removal with proper EOF handling.

**BUG-004: `grep -oP` requires Perl regex — not portable**
- File: `directive-ctl.sh` lines 28, 64
- macOS ships BSD grep which has no `-P` flag. Since OpenClaw's primary 
  audience skews heavily macOS (M-series Macs), this is a launch blocker.
- **Impact**: `directive-ctl add` and `list` crash on macOS.
- **Fix**: Use `grep -oE` with POSIX ERE, or awk/sed.

---

### 🟡 SECURITY ISSUES (5)

**SEC-001: No file locking — race condition on concurrent writes**
- Both `guardian.sh` and `directive-ctl.sh` read/write the registry and 
  log without any locking. If a cron heartbeat fires while the user is 
  adding a directive, both can corrupt the file.
- **Fix**: Use `flock` advisory locking.

**SEC-002: No input validation on `add` command arguments**
- Priority accepts any string — no validation against allowed values.
  Category and directive text are injected raw into markdown.
  A malicious or accidental `directive` value containing `## [DIRECTIVE-` 
  could inject a fake directive block.
- **Fix**: Validate priority enum, sanitize inputs.

**SEC-003: Unquoted variable expansions in sed/grep patterns**
- `$target` in sed patterns could contain regex metacharacters. While 
  DIRECTIVE-XXX format is safe, defense-in-depth requires escaping.
- **Fix**: Escape regex metacharacters in user-supplied patterns.

**SEC-004: No registry integrity checking**
- No checksum, no signature, no tamper detection. If another process or 
  skill modifies `directives.md`, the guardian blindly trusts it.
- **Fix**: SHA-256 checksum stored separately, verified on boot.

**SEC-005: Log file grows unbounded**
- No rotation, no max size. A cron heartbeat every 6 hours = 1,460 log 
  entries/year minimum. With verbose operations, could grow to megabytes.
- **Fix**: Built-in log rotation (keep last N lines or last N days).

---

### 🟠 MISSING FEATURES (7)

**FEAT-001: No enable/disable toggle**
- Can't temporarily disable a directive without deleting it. Users need 
  a way to test behavior without a directive, then re-enable it.

**FEAT-002: No backup before destructive operations**
- `remove` and `add` modify the registry with no backup. One bad sed 
  command and the registry is gone.

**FEAT-003: No export/import**
- Can't share directive sets between Claw instances or version them in git.

**FEAT-004: No `edit` command**
- To modify a directive, user must manually edit the markdown file.
  Should have `directive-ctl edit DIRECTIVE-001 --directive "new text"`.

**FEAT-005: No search/filter by category or keyword**
- With 50+ directives, `list` becomes useless. Need filtering.

**FEAT-006: No diff reporting**
- The guardian claims to "diff against current context" but there's no 
  actual diff output. User can't see what was missing vs what was fine.

**FEAT-007: No test/validation harness**
- No way to verify the skill works correctly before deploying. No test 
  script, no self-check, no dry-run mode.

---

### 🔵 END-USER PERSPECTIVE ISSUES (2)

**UX-001: No onboarding flow**
- First-time user gets an empty registry and no guidance. Should auto-detect 
  existing OpenClaw memory files and offer to import directives from them.

**UX-002: Silent reapply gives zero feedback**
- "Silent" is correct for normal operation, but there's no way to verify 
  it actually ran. Need at minimum a boot summary the agent can optionally 
  surface: "Guardian: 12/12 directives verified ✓"
