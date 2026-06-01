# Claude Code Status Line

A visual status line script for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that displays context window usage, session cost, duration, model info, and git status.

## Preview

```
◔ 12% | Opus 4.7 | 🧠high | +9% spare
2 files | 2m00s | A$0.71 | main
```

## Features

- **Context window gauge** with rotating dial icon (`◔ → ◑ → ●`) and percent only — colour-coded by usage zone with a `compact soon` / `compact now` hint when needed.
- **Thread-health counter** (`💬N`) that nudges you before a thread gets expensive or loses its plot. Counts genuine human prompts **since the last compaction** (it resets at a compaction boundary, so an in-session `/compact` gives you a fresh count rather than a stale running total). Staged hints on the message count:
  - `< 150` (grey) — plenty of headroom.
  - `150+` (yellow) `⚠ plan handoff` — getting long, pick a handoff point.
  - `300+` (orange) `👝 handoff + fresh chat` — reopen in a fresh session before it loses the plot.
  - `2000+` (red) `🛑 compact or new chat` — hard stop; the per-message context tax is now pure waste.
- **Delegation meter** (`🤖N`) — counts subagent dispatches (`Agent`/`Task` tool uses) in the session. The main session is meant to orchestrate, not hand-drive; the costliest sessions are long threads with zero delegation. Behaviour:
  - any dispatches → grey `🤖N`, no nag.
  - long thread (40+ turns) with **zero** dispatches → red `🤖0 🛑 delegate`, flagging that the orchestrator-only pattern is being ignored.
  - short thread with zero dispatches → hidden (normal early conversation).
- **Session cost** in AUD (configurable exchange rate)
- **Session duration** with adaptive formatting (`45s`, `12m34s`, `1h02m`)
- **Reasoning effort** indicator with colour coding: green (`⚡low`), yellow (`⚙ med`), magenta (`🧠high`)
- **Git info**: branch, clean/dirty status, changed file count
- **7-day Anthropic Max quota pace** as a single status chunk on line 1. One of:
  - `+N% spare` (green) — you're under pace by N percentage points; room to spare.
  - `on track` (yellow) — within ±7% of where you should be.
  - `-N% over` (orange) — over pace by N percentage points but projected to land under 100%.
  - `🛑 over pace` (red) — projected end-of-week usage is at or above 100%.

  Greyed out if the source cache hasn't refreshed in 30+ minutes. Data source: the Raycast "Claude Usage" extension cache. The script auto-discovers the cache file once and stores its path in `~/.claude/state/seven-day-usage-cache-path`. The chunk is hidden when that data is unavailable.

## Codex Usage Tracker

`codex-usage.sh` is a companion tracker for Codex Desktop/CLI. It reads Codex's local session JSONL logs under `~/.codex/sessions` and renders the latest 7-day quota pace from Codex `rate_limits`, falling back to the newest recent quota snapshot if the active session has null quota fields.

Preview:

```text
▓▓▓░│░░░░░ 28% · +14% spare
```

Run it directly:

```bash
chmod +x codex-usage.sh
./codex-usage.sh
```

Inspect a specific Codex session:

```bash
./codex-usage.sh --file ~/.codex/sessions/2026/05/13/rollout-example.jsonl
```

For a plain, no-colour output suitable for scripts:

```bash
NO_COLOR=1 ./codex-usage.sh
```

For debugging, `./codex-usage.sh --full` also shows context percentage, 5-hour quota, token usage, model, effort, messages, plan type, and workspace.

Watch mode refreshes once per minute:

```bash
./codex-usage.sh --live
```

If installed as a Fish function, use:

```fish
codex-usage --live
```

This is usage tracking, not invoice-grade billing. Codex session logs expose quota percentages and token counts, but not a stable per-turn dollar cost. If Codex later exposes official cost fields or a status-line hook, this script can adopt those without changing the display shape.

## Claude Usage Tracker

`claude-usage.sh` renders the same 7-day Claude Max quota pace signal as a compact bar, sourced from the Raycast Claude Usage extension cache.

Preview:

```text
▓▓▓░│░░░░░ 28% · +14% spare
```

Run it directly:

```bash
chmod +x claude-usage.sh
./claude-usage.sh
```

Watch mode refreshes once per minute:

```bash
./claude-usage.sh --live
```

If installed as a Fish function, use:

```fish
claude-usage
claude-usage --live
```

## Combined AI Usage

`ai-usage.sh` combines the Codex and Claude bars in one command.

Preview:

```text
codex  ▓▓░│░░░░░░ 24% · +7% spare
claude ▓▓▓░│░░░░░ 28% · +14% spare
```

Run it directly:

```bash
chmod +x ai-usage.sh
./ai-usage.sh
```

Watch mode refreshes once per minute:

```bash
./ai-usage.sh --live
```

If installed as a Fish function, use:

```fish
ai-usage
ai-usage --live
```

## Installation

### Prerequisites

- `jq` for JSON parsing
- `bc` for cost calculation
- `git` (optional, for git status features)
- `python3` for relative reset-time formatting in the Codex usage tracker

### Setup

1. Copy `status-line.sh` to your Claude Code hooks directory:

```bash
mkdir -p ~/.claude/hooks.global
cp status-line.sh ~/.claude/hooks.global/status-line.sh
chmod +x ~/.claude/hooks.global/status-line.sh
```

2. Add the hook to your Claude Code settings (`~/.claude/settings.json`):

```json
{
  "hooks": {
    "StatusLine": [
      {
        "type": "command",
        "command": "bash ~/.claude/hooks.global/status-line.sh"
      }
    ]
  }
}
```

## Configuration

### Currency

The cost display defaults to AUD. To change the currency or exchange rate, edit the conversion section in `status-line.sh`:

```bash
# Convert USD to AUD (update rate periodically)
usd_to_aud=1.42
```

To display in USD instead, replace the cost block with:

```bash
session_cost=$(printf "%.2f" "$session_cost")
cost_display=$(printf "\033[33m\$%s\033[0m" "$session_cost")
```

## Status Line JSON Input

The script reads JSON from stdin provided by Claude Code. Available fields include:

| Field | Description |
|-------|-------------|
| `model.display_name` | Current model name |
| `output_style.name` | Output style (e.g. explanatory, concise) |
| `workspace.project_dir` | Project directory path |
| `context_window.used_percentage` | Context window usage percentage |
| `context_window.current_usage.input_tokens` | Current input token count |
| `context_window.context_window_size` | Total context window size |
| `cost.total_cost_usd` | Cumulative session cost in USD |
| `cost.total_duration_ms` | Session wall-clock time in milliseconds |
| `reasoning_effort` | Reasoning effort level (low, medium, high) |

## Licence

MIT
