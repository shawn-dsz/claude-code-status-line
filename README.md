# Claude Code Status Line

A visual status line script for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that displays context window usage, session cost, duration, model info, and git status.

## Preview

```
◑ 49% ▁▂▃▄▁▁▁▁ 498k/1.0M | A$1.74 | 12m34s | Opus 4.6 | explanatory | ⚙ med | /my/project | main | clean | 0 files | +0/-0
```

## Features

- **Context window gauge** with rotating dial icon (`◔ → ◑ → ◶ → ●`), mini bar graph, and token count
- **Colour-coded usage**: green (0-50%), yellow (50-75%), orange (75-90%), red (90%+)
- **Session cost** in AUD (configurable exchange rate)
- **Session duration** with adaptive formatting (`45s`, `12m34s`, `1h02m`)
- **Reasoning effort** indicator with colour coding: green (`⚡low`), yellow (`⚙ med`), magenta (`🧠high`)
- **Git info**: branch, clean/dirty status, changed file count, lines added/removed

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
