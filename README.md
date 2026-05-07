# Claude Code Status Line

A visual status line script for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that displays context window usage, session cost, duration, model info, and git status.

## Preview

```
◔ 12% | Opus 4.7 | 🧠high | +9% spare
2 files +96/-48 | 2m00s | A$0.71 | main
```

## Features

- **Context window gauge** with rotating dial icon (`◔ → ◑ → ●`) and percent only — colour-coded by usage zone with a `compact soon` / `compact now` hint when needed.
- **Session cost** in AUD (configurable exchange rate)
- **Session duration** with adaptive formatting (`45s`, `12m34s`, `1h02m`)
- **Reasoning effort** indicator with colour coding: green (`⚡low`), yellow (`⚙ med`), magenta (`🧠high`)
- **Git info**: branch, clean/dirty status, changed file count, lines added/removed
- **7-day Anthropic Max quota pace** as a single status chunk on line 1. One of:
  - `+N% spare` (green) — you're under pace by N percentage points; room to spare.
  - `on track` (yellow) — within ±7% of where you should be.
  - `-N% over` (orange) — over pace by N percentage points but projected to land under 100%.
  - `🛑 over pace` (red) — projected end-of-week usage is at or above 100%.

  Greyed out if the source cache hasn't refreshed in 30+ minutes. Data source: the Raycast "Claude Usage" extension cache. The script auto-discovers the cache file once and stores its path in `~/.claude/state/seven-day-usage-cache-path`. The chunk is hidden when that data is unavailable.

## Installation

### Prerequisites

- `jq` for JSON parsing
- `bc` for cost calculation
- `git` (optional, for git status features)

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
