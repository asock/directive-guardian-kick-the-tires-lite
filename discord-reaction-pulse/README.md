# 🫀 discord-reaction-pulse

**Dynamic-cadence Discord reaction skill for [OpenClaw](https://openclaw.ai)**

Lets your AI agent post contextual emoji reactions onto a Discord message at
an interval that compresses as the project nears completion. Slow drip in the
research phase, rapid-fire in the final push.

## Why

Status updates in chat are noise. A reaction on the *right* message says "I'm
still working" without pinging anyone. And a reaction cadence that visibly
accelerates as the project nears 100% gives the room a heartbeat — you can
*feel* the project getting close to ship without anyone typing a word.

## Features

- **Progress-driven cadence** — `interval = min + (max - min) * (1 - p)^curve`
- **Tunable acceleration curve** — back-load the speed-up so the final 25%
  of progress feels like rapid-fire
- **Tiered emoji bands** — seedling → building → pushing → crunching → shipping
- **Context tags** — `feat` / `bug` / `test` / `docs` / `ship` bias the picker
  toward topic-appropriate icons
- **Round-robin within tier** — no two consecutive reactions repeat
- **One-off or daemon mode** — fire a single reaction or run the loop in the
  background
- **Live re-tuning** — edit state while the daemon runs, changes apply on the
  next iteration (no signals required)
- **Dry-run mode** — `PULSE_DRY_RUN=true` exercises the full pipeline without
  hitting the network
- **POSIX portable** — bash + `awk` + `od` + `curl`. No `jq`, no `bc`, no Python
- **Audit log** — every pulse logged with band, tag, emoji, and computed next
  interval; auto-rotated at 500 lines

## Install

Drop the folder into your OpenClaw skills directory:

```bash
cp -r discord-reaction-pulse ~/.openclaw/skills/
```

Reference it from your agent's persona prompt or boot manifest.

## Quick Start

```bash
cd ~/.openclaw/skills/discord-reaction-pulse

# 1. Bootstrap state
./scripts/pulse-ctl.sh init

# 2. Tell it which Discord message to react on
./scripts/pulse-ctl.sh target 123456789012345678 234567890123456789

# 3. Set the project tag
./scripts/pulse-ctl.sh tag feat

# 4. Set the bot token (in your shell rc, ideally)
export DISCORD_BOT_TOKEN='...'

# 5. Preview what the next reaction would be (no network)
./scripts/pulse-ctl.sh preview

# 6. Fire one reaction now
./scripts/pulse-ctl.sh react

# 7. Or start the background daemon
./scripts/pulse-ctl.sh start

# 8. Mark progress as work gets done — the daemon catches up automatically
./scripts/pulse-ctl.sh progress 25
./scripts/pulse-ctl.sh bump 10        # → 35
./scripts/pulse-ctl.sh progress 90    # interval crunches down hard

# 9. Check on it
./scripts/pulse-ctl.sh status

# 10. Stop the pulse
./scripts/pulse-ctl.sh stop
```

## How fast is "fast"?

With the default `base_interval_sec=300`, `min_interval_sec=15`, `curve=1.8`:

| Progress | Interval | Description     |
|---------:|---------:|:----------------|
|       0% |  300 sec | slow drip       |
|      10% |  251 sec |                 |
|      25% |  185 sec |                 |
|      50% |   97 sec | steady tap      |
|      75% |   39 sec |                 |
|      90% |   20 sec | crunching       |
|     100% |   15 sec | rapid-fire ship |

Tighten the speed-up by raising `curve` (try `2.5`); flatten it by lowering
`curve` toward `1.0` (linear).

```bash
./scripts/pulse-ctl.sh tune curve=2.5 base_interval_sec=600 min_interval_sec=10
```

## Emoji Tiers

```
seedling   (0–24%)   🌱 💭 🧠
building   (25–49%)  🔨 ⚙️ 🛠️
pushing    (50–74%)  ⏳ 📈 🎯
crunching  (75–94%)  🔥 ⚡ 💪
shipping   (95–100%) 🚀 ✅ 🎉 🏁
```

Each tier × tag pairing has its own list — see `config/reactions.conf` for the
full table. Override by editing the conf file; the picker re-reads it on every
pulse.

## Environment Variables

| Variable              | Default                           | Purpose                       |
|-----------------------|-----------------------------------|-------------------------------|
| `DISCORD_BOT_TOKEN`   | (required for live reactions)     | Bot token                     |
| `DISCORD_API_BASE`    | `https://discord.com/api/v10`     | API base URL                  |
| `OPENCLAW_MEMORY_DIR` | `~/.openclaw/memory`              | State + log directory         |
| `PULSE_DRY_RUN`       | `false`                           | Skip network calls            |
| `PULSE_USER_AGENT`    | `OpenClawDiscordReactionPulse/1.0`| Discord-required UA header    |

## Running Tests

```bash
bash tests/test_pulse.sh
```

The harness is fully offline — it stubs `curl` so the math, picker, state I/O,
log rotation, and CLI plumbing can be exercised in CI without a Discord token.

## Files

```
discord-reaction-pulse/
├── SKILL.md
├── README.md
├── scripts/
│   ├── pulse.sh
│   ├── pulse-ctl.sh
│   ├── reactor.sh
│   ├── interval.sh
│   └── emoji-picker.sh
├── config/
│   └── reactions.conf
└── tests/
    └── test_pulse.sh
```

## License

MIT — see [../LICENSE](../LICENSE).
