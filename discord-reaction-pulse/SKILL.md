---
name: discord-reaction-pulse
description: >
  Lets the OpenClaw host agent push contextually-relevant emoji reactions onto
  a target Discord message at a cadence that dynamically accelerates as the
  tracked project nears completion. Use this skill whenever the user asks the
  agent to "react on Discord", "pulse a reaction", "set project progress",
  "mark progress", "start the reaction pulse", "stop the pulse", "react faster",
  "react slower", "tag this project as <feat|bug|test|docs|ship>", or
  "show pulse status". Use this skill on any request to add a one-off Discord
  reaction, change the target message, or run the background reaction daemon.
---

# Discord Reaction Pulse v1

Gives the host robot a heartbeat on Discord. Posts emoji reactions onto a
chosen message at an interval that compresses as project progress climbs
toward 100%, so the room can *feel* the project nearing the finish line.

## Mental Model

```
   progress 0%        progress 50%        progress 100%
   slow drip          steady tap          rapid-fire
   ──┬──── 🌱 ────────┬─── 🔨 ────────────┬─ 🚀✅🎉🏁
     5 min             90 sec               15 sec
```

The cadence is computed from the tracked progress value, NOT a wall-clock
deadline. You set progress as work gets done; the daemon sees the change on
its next loop iteration and tightens the interval automatically.

## Architecture

```
~/.openclaw/memory/discord-pulse/
├── state                  # canonical key=value state file
├── state.bak              # auto-backup before destructive ops
├── pulse.pid              # daemon PID (only present when running)
├── pulse.log              # rotated audit log (max 500 lines)
└── last-response.json     # most recent Discord API response body
```

The skill itself ships:

```
discord-reaction-pulse/
├── SKILL.md               # this file
├── README.md              # human-facing overview
├── scripts/
│   ├── pulse.sh           # daemon loop / one-shot mode
│   ├── pulse-ctl.sh       # CLI: start/stop/status/progress/tag/target/react
│   ├── reactor.sh         # Discord API wrapper (PUT reaction)
│   ├── interval.sh        # progress → interval math (pure)
│   └── emoji-picker.sh    # tier + tag → emoji (pure)
├── config/
│   └── reactions.conf     # tier × tag → emoji table (overridable)
└── tests/
    └── test_pulse.sh      # POSIX test harness, no network
```

## State File (`state`)

Plain `key=value` (one per line). The daemon and CLI both read and write it.

| Key                  | Type    | Default | Description                                    |
|----------------------|---------|---------|------------------------------------------------|
| `progress`           | int     | `0`     | Project completion percent, 0–100              |
| `channel_id`         | string  | (empty) | Discord channel snowflake                      |
| `message_id`         | string  | (empty) | Target message snowflake                       |
| `tag`                | enum    | `feat`  | `feat` / `bug` / `test` / `docs` / `ship`     |
| `base_interval_sec`  | int     | `300`   | Slowest interval (used at progress=0)          |
| `min_interval_sec`   | int     | `15`    | Fastest interval (used at progress=100)        |
| `curve`              | float   | `1.8`   | Acceleration exponent; >1 = more aggressive    |
| `max_pulses`         | int     | `0`     | Daemon stop after N pulses; `0` = infinite     |
| `last_pulse_ts`      | epoch   | `0`     | Unix timestamp of last successful reaction     |
| `last_emoji`         | string  | (empty) | Most-recently-fired emoji                      |
| `pulse_count`        | int     | `0`     | Total reactions fired since start              |
| `tier_cursor`        | int     | `0`     | Round-robin index inside the active tier       |

## Cadence Formula

```
p        = clamp(progress / 100, 0, 1)
interval = min_interval_sec + (base_interval_sec - min_interval_sec) * (1 - p) ** curve
```

With `curve = 1.8` the interval shrinks faster than a straight linear ramp at
every progress level (the curve sits below the linear baseline) and crunches
down to `min_interval_sec` dramatically in the last 25%. Raise `curve` to make
the speed-up more aggressive overall; lower it toward `1.0` for a soft, almost
linear ramp; values below `1.0` give an even gentler cadence.

| Progress | Interval (default config) |
|---------:|--------------------------:|
|       0% |                   300 sec |
|      25% |                   185 sec |
|      50% |                    97 sec |
|      75% |                    39 sec |
|      90% |                    20 sec |
|     100% |                    15 sec |

## Tier Bands & Emoji

The picker splits progress into 5 bands. Each `(band, tag)` cell yields a list
of emoji that cycle round-robin via `tier_cursor`, so reactions don't repeat
the same icon back-to-back.

| Band       | Range    | Generic     | feat | bug  | test | docs | ship  |
|------------|----------|-------------|------|------|------|------|-------|
| seedling   | 0–24%    | 🌱 💭 🧠    | 💡   | 🔍   | 🧪   | 📝   | 📦    |
| building   | 25–49%   | 🔨 ⚙️ 🛠️   | 🏗️  | 🐛   | 🧫   | 📚   | 📐    |
| pushing    | 50–74%   | ⏳ 📈 🎯    | 🚧   | 🩹   | ✅   | ✍️   | 📤    |
| crunching  | 75–94%   | 🔥 ⚡ 💪   | ✨   | 🔧   | 🟢   | 🖋️  | 🛫    |
| shipping   | 95–100%  | 🚀 ✅ 🎉 🏁 | 🚀   | ✔️   | 🟩   | 📖   | 🎊    |

The exact mapping lives in `config/reactions.conf` and is overridable.

## CLI Commands (`scripts/pulse-ctl.sh`)

| Command                                   | Action                                              |
|-------------------------------------------|-----------------------------------------------------|
| `init`                                    | Bootstrap memory dir + default state file           |
| `target <channel_id> <message_id>`        | Set the Discord message that gets reacted on        |
| `progress <0-100>`                        | Set project progress percent                        |
| `bump <delta>`                            | Adjust progress by delta (e.g. `bump 5`, `bump -3`) |
| `tag <feat\|bug\|test\|docs\|ship>`       | Set the active context tag                          |
| `tune <key=value> [...]`                  | Set tuning keys (`base_interval_sec`, `curve`, …)   |
| `react [--emoji <e>]`                     | Fire one reaction immediately                       |
| `preview`                                 | Show next emoji + computed interval, no network     |
| `start [--foreground]`                    | Start the pulse daemon (default: background)        |
| `stop`                                    | Stop the pulse daemon                               |
| `status`                                  | Show full state, computed interval, last 10 logs    |
| `validate`                                | Check state file + config + env vars                |
| `reset`                                   | Reset state to defaults (with backup)               |
| `log [N]`                                 | Tail last N log entries (default 25)                |
| `help`                                    | Usage                                               |

## Environment

| Variable               | Required        | Description                                 |
|------------------------|-----------------|---------------------------------------------|
| `DISCORD_BOT_TOKEN`    | yes (for react) | Bot token used in `Authorization: Bot ...`  |
| `DISCORD_API_BASE`     | no              | Default `https://discord.com/api/v10`       |
| `OPENCLAW_MEMORY_DIR`  | no              | Default `~/.openclaw/memory`                |
| `PULSE_DRY_RUN`        | no              | If `true`, log calls but skip the network   |
| `PULSE_USER_AGENT`     | no              | UA header sent to Discord                   |

## Agent Trigger Phrases

| Phrase                                          | Action                                |
|-------------------------------------------------|---------------------------------------|
| `start the pulse` / `pulse on`                 | `pulse-ctl start`                     |
| `stop the pulse` / `pulse off`                 | `pulse-ctl stop`                      |
| `pulse status` / `how's the pulse`             | `pulse-ctl status`                    |
| `set project progress to N` / `progress N`     | `pulse-ctl progress N`                |
| `bump progress N`                              | `pulse-ctl bump N`                    |
| `tag this as feat\|bug\|test\|docs\|ship`      | `pulse-ctl tag <tag>`                 |
| `react on discord` / `drop a reaction`          | `pulse-ctl react`                     |
| `target message <channel> <msg>`               | `pulse-ctl target <c> <m>`            |
| `slow down the pulse` / `speed up the pulse`   | `pulse-ctl tune base_interval_sec=…`  |
| `preview next reaction`                        | `pulse-ctl preview`                   |

## Reaction Strategy

Each daemon iteration:

1. Re-read state file (so live edits are picked up immediately)
2. Compute current band and interval from `progress`
3. Pick emoji from `(band, tag)` cell, advancing `tier_cursor` round-robin
4. POST reaction via `reactor.sh` (or skip if `PULSE_DRY_RUN=true`)
5. Update `last_pulse_ts`, `last_emoji`, `pulse_count`
6. Log the event: `PULSE  band=pushing  tag=feat  emoji=🚧  next=87s`
7. Sleep `interval` seconds
8. If `max_pulses > 0` and `pulse_count >= max_pulses`, exit cleanly

If progress hits 100, the daemon fires one final ship-band reaction, logs
`PULSE_COMPLETE`, and exits regardless of `max_pulses`.

## Error Handling

| Condition                       | Behavior                                          |
|---------------------------------|---------------------------------------------------|
| `DISCORD_BOT_TOKEN` unset       | One-off `react`: error out. Daemon: log + sleep. |
| Discord API returns 4xx         | Log `REACT_FAIL <code>`, do NOT crash daemon     |
| Discord API returns 429         | Honour `Retry-After`, sleep, retry once          |
| State file missing              | Auto-bootstrap with defaults, log `BOOTSTRAP`    |
| `channel_id`/`message_id` blank | Skip reaction, log `NO_TARGET`, keep looping     |
| Malformed `progress` value      | Clamp to 0–100, log `PROGRESS_CLAMPED`           |
| Lock file held by other PID     | Exit with `LOCK_HELD`, do not double-start       |
| `pulse.log` > 500 lines         | Auto-rotate (keep last 250 lines)                |

## Integration Notes

- **One-off vs daemon**: `pulse-ctl react` posts a single reaction immediately
  using current state. `pulse-ctl start` runs the loop in the background. Both
  share the same emoji-picker so previews are consistent.
- **Live re-tuning**: Edit `state` while the daemon runs — the next iteration
  picks up your changes (no SIGHUP needed).
- **Multi-message**: Stop the daemon, change `target`, and start again. State
  is intentionally single-target to keep the formula simple.
- **Custom emojis**: For server-specific emoji, store as `name:id` in
  `reactions.conf`. The reactor URL-encodes them transparently.
