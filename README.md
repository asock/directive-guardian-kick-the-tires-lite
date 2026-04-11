# 🛡️ directive-guardian

**Persistent memory integrity skill for [OpenClaw](https://openclaw.ai)**

Ensures your AI agent's learned directives survive resets, context window rotations, and other memory mishaps. Maintains a canonical markdown registry with SHA-256 integrity verification, priority-ordered reinjection, and a full management CLI.

## Why

AI agents forget. Context windows rotate. Sessions reset. Your carefully taught persona, tool preferences, and project awareness vanish. Directive Guardian keeps a source-of-truth registry and silently reinjects everything on boot — so your agent always knows who it is.

## Features

- **Boot-time reapply** — Parses registry, sorts by priority (critical → low), reinjects into session
- **Enable/disable toggle** — Test without a directive without deleting it
- **SHA-256 integrity checks** — Detects unauthorized registry modifications
- **Advisory file locking** — Safe concurrent access via `flock`
- **Auto-rotating audit log** — Every reapply logged, capped at 500 lines
- **Backup/restore** — Auto-backup before every destructive operation
- **Export/import** — Sync directive sets between Claw instances via JSON
- **Validation** — Catch malformed directives before they cause boot failures
- **POSIX portable** — Runs on Linux and macOS (no gawk/GNU-only extensions)

## Install

Clone this repo into your OpenClaw skills directory (the repo root *is*
the skill):

```bash
git clone https://github.com/asock/directive-guardian-kick-the-tires-lite \
  ~/.openclaw/skills/directive-guardian
chmod +x ~/.openclaw/skills/directive-guardian/scripts/*.sh
```

Add it to your agent's boot sequence or reference it in your system prompt.

## Quick Start

```bash
# Bootstrap (creates registry if it doesn't exist)
~/.openclaw/skills/directive-guardian/scripts/guardian.sh

# Add directives
./scripts/directive-ctl.sh add "Core Persona" critical identity "You are my AI agent. Be direct and technical."
./scripts/directive-ctl.sh add "Tool Prefs" high tooling "Prefer ripgrep over grep. Use Docker for isolation."

# List everything
./scripts/directive-ctl.sh list

# Filter by priority or category
./scripts/directive-ctl.sh list --priority critical
./scripts/directive-ctl.sh list --category tooling

# Temporarily disable a directive
./scripts/directive-ctl.sh disable DIRECTIVE-002

# Re-enable
./scripts/directive-ctl.sh enable DIRECTIVE-002

# Edit in place
./scripts/directive-ctl.sh edit DIRECTIVE-001 --directive "Updated persona text"

# Search across all directives
./scripts/directive-ctl.sh search "docker"

# Check integrity and status
./scripts/directive-ctl.sh status

# Validate registry for errors
./scripts/directive-ctl.sh validate

# Backup / restore
./scripts/directive-ctl.sh backup
./scripts/directive-ctl.sh restore

# Export for syncing between instances
./scripts/directive-ctl.sh export directives.json
./scripts/directive-ctl.sh import directives.json
```

## Registry Format

Directives live in `~/.openclaw/memory/directives.md`:

```markdown
## [DIRECTIVE-001] Core Persona
- **priority**: critical
- **category**: identity
- **enabled**: true
- **directive**: You are my AI agent. Be direct and technical.
- **verify**: Check that persona definition is loaded in system context.
```

| Field      | Required | Values                                 |
|------------|----------|----------------------------------------|
| priority   | yes      | `critical` / `high` / `medium` / `low` |
| category   | yes      | Any grouping tag                       |
| enabled    | yes      | `true` / `false`                       |
| directive  | yes      | The instruction to reinject            |
| verify     | no       | Hint for how to confirm it's active    |

## Agent Trigger Phrases

Your agent should respond to these naturally:

| Phrase                 | Action                          |
|------------------------|---------------------------------|
| `check directives`    | Report status of all directives |
| `reapply memory`      | Force full reapply              |
| `directive status`    | Full status table + integrity   |
| `add directive <text>` | Append new directive           |
| `did you forget anything` | Run audit check             |

## Architecture

```
~/.openclaw/memory/
├── directives.md              # canonical registry (source of truth)
├── directives.md.bak          # auto-backup before destructive ops
├── directives.sha256          # integrity checksum
├── directive-guardian.log     # audit log (auto-rotated)
```

## Running Tests

```bash
bash tests/test_guardian.sh
```

69 tests covering bootstrap, CRUD, filtering, parsing, enable/disable,
edit, search, remove, validation, input sanitization, backup/restore,
export/import, checksum/integrity, log rotation, the status dashboard,
and explicit regressions for every bug catalogued in `AUDIT.md`
(BUG-001..004, SEC-001..005, FEAT-001..007).

## Environment

| Variable                 | Default              | Description                            |
|--------------------------|----------------------|----------------------------------------|
| `OPENCLAW_MEMORY_DIR`    | `~/.openclaw/memory` | Registry location                      |
| `GUARDIAN_DRY_RUN`       | `false`              | Skip checksum updates                  |
| `GUARDIAN_STRICT`        | `false`              | Exit non-zero on integrity mismatch    |
| `GUARDIAN_LOCK_TIMEOUT`  | `10`                 | Lock wait in seconds                   |
| `GUARDIAN_LOG_MAX_LINES` | `500`                | Log rotation threshold                 |
| `GUARDIAN_QUIET`         | `false`              | Suppress guardian stderr warnings      |
| `GUARDIAN_YES`           | `false`              | Skip confirm prompts on destructive ops|
| `NO_COLOR`               | unset                | Disable ANSI color in `directive-ctl`  |

## Optional Dependencies

| Tool  | Required | Used For                     |
|-------|----------|------------------------------|
| `jq`  | No       | Priority sorting, import/export |
| `flock` | No     | Advisory file locking (Linux) |

Both degrade gracefully — sorting falls back to parse order, locking is skipped on macOS.

## License

MIT — see [LICENSE](LICENSE).

## Author

Built for the [hellsy.net](https://hellsy.net) network.
