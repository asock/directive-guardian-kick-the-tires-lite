---
name: directive-guardian
description: >
  Persistent memory integrity skill for OpenClaw. On every boot, restart, 
  or context reset, scans the directive registry (markdown memory files) and 
  silently reapplies any missing or degraded directives with priority ordering 
  and integrity verification. Use this skill on startup, after any reset, or 
  when the agent detects memory drift. Also triggers when the user says 
  "check directives", "reapply memory", "memory audit", "directive check", 
  "directive status", "did you forget anything", "what do you remember", 
  or "guardian status". Use this skill for any request to add, remove, edit, 
  enable, disable, search, export, import, or backup learned directives.
---

# Directive Guardian v2

Ensures learned directives survive resets, context window rotations, and
other AI memory mishaps by maintaining a canonical registry with integrity
verification, priority-ordered reinjection, and a full management CLI.

## Architecture

```
~/.openclaw/memory/
├── directives.md              # canonical registry (source of truth)
├── directives.md.bak          # auto-backup before destructive ops
├── directives.sha256           # integrity checksum
├── directive-guardian.log      # audit log (auto-rotated, max 500 lines)
```

## Registry Format (`directives.md`)

```markdown
## [DIRECTIVE-001] Persona & Identity
- **priority**: critical
- **category**: identity
- **enabled**: true
- **directive**: You are [name]. You speak in [tone].
- **verify**: Check system prompt contains persona definition.
```

### Fields

| Field        | Required | Description                                            |
|------------- |----------|--------------------------------------------------------|
| `ID`         | yes      | `[DIRECTIVE-NNN]` in heading — unique, zero-padded     |
| `priority`   | yes      | `critical` / `high` / `medium` / `low`                 |
| `category`   | yes      | Freeform grouping tag for filtering                    |
| `enabled`    | yes      | `true` / `false` — toggle without deleting             |
| `directive`  | yes      | The instruction text to reinject                       |
| `verify`     | no       | Hint for how to confirm it's active                    |

## Boot Sequence

On startup, run `scripts/guardian.sh`. It will:

1. Acquire an advisory file lock (prevents race conditions)
2. Verify registry integrity via SHA-256 checksum
3. Parse all directive blocks into sorted JSON (critical → low)
4. Skip disabled directives (enabled: false)
5. Output JSON manifest to stdout for agent consumption
6. Log the audit with per-directive status
7. Auto-rotate the log if it exceeds 500 lines

The agent reads the JSON and reinjects each directive into active context.

## CLI Commands (`scripts/directive-ctl.sh`)

| Command                                        | Action                                       |
|------------------------------------------------|----------------------------------------------|
| `add <title> <priority> <category> <text>`     | Append new directive, auto-assigns next ID   |
| `remove <ID>`                                  | Remove directive (with backup + confirmation)|
| `edit <ID> --directive "new text"`             | Modify a directive's text in place           |
| `edit <ID> --priority high`                    | Change priority                              |
| `enable <ID>`                                  | Set enabled: true                            |
| `disable <ID>`                                 | Set enabled: false (keeps directive in file)  |
| `list [--category <tag>] [--priority <level>]` | List directives with optional filters        |
| `search <keyword>`                             | Full-text search across all directives       |
| `status`                                       | Show last 15 log entries + integrity status  |
| `backup`                                       | Create timestamped backup of registry        |
| `restore [file]`                               | Restore from backup                          |
| `export [file]`                                | Export registry as portable JSON             |
| `import <file>`                                | Import directives from JSON export           |
| `checksum`                                     | Recalculate and store SHA-256 checksum       |
| `validate`                                     | Parse check — reports malformed blocks       |
| `help`                                         | Usage info                                   |

## Agent Trigger Phrases

| Trigger                        | Action                                           |
|--------------------------------|--------------------------------------------------|
| `(on boot / restart)`          | Full registry scan + silent reapply              |
| `check directives`             | Report status of all directives to user          |
| `reapply memory`               | Force full reapply including already-active ones |
| `add directive <text>`         | Append new directive via CLI                     |
| `remove directive <ID>`        | Remove directive via CLI                         |
| `disable directive <ID>`       | Temporarily disable without deleting             |
| `enable directive <ID>`        | Re-enable a disabled directive                   |
| `directive status`             | Full status table + integrity check              |
| `search directives <keyword>`  | Search by keyword across all fields              |
| `backup directives`            | Create a timestamped backup                      |
| `export directives`            | Export as portable JSON                          |

## Reapply Strategy

1. Read `directives.md` from memory directory
2. Parse all `## [DIRECTIVE-NNN]` blocks
3. Filter out `enabled: false` directives
4. Sort by priority: critical → high → medium → low
5. Reinject each into current session context
6. Log per-directive: `REAPPLIED`, `SKIPPED (disabled)`, or `PARSE_ERROR`
7. Summary line: `AUDIT OK — 10/12 directives applied, 2 disabled`

## Auto-Learn Integration

When the user teaches the agent something that should persist, the agent
should ask: *"Should I save this as a permanent directive?"*  
If yes: run `directive-ctl.sh add` with appropriate metadata.

## Error Handling

| Condition                    | Behavior                                    |
|------------------------------|---------------------------------------------|
| Registry missing             | Create with header, log BOOTSTRAP warning   |
| Memory dir missing           | Create it, log BOOTSTRAP event              |
| Malformed directive block    | Skip it, log PARSE_ERROR, continue others   |
| Checksum mismatch            | Log INTEGRITY_WARNING, still parse but warn |
| Lock acquisition timeout     | Exit with error, log LOCK_TIMEOUT           |
| Empty registry               | Log EMPTY_REGISTRY, output empty manifest   |

## Integration Notes

- **Boot**: Add `directive-guardian` to your startup skills or persona prompt
- **Heartbeat**: Wire to OpenClaw cron for periodic re-verification
  (recommended: every 4 hours for long sessions)
- **Git**: The registry is plain markdown — commit it to your dotfiles repo
- **Multi-instance**: Use `export`/`import` to sync between Claw instances
