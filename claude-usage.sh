#!/bin/bash
# Usage tracker for Claude Max 7-day usage via the Raycast Claude Usage cache.

set -euo pipefail

colour() {
    local code="$1"
    local text="$2"
    if [ -n "${NO_COLOR:-}" ]; then
        printf "%s" "$text"
    else
        printf "\033[%sm%s\033[0m" "$code" "$text"
    fi
}

usage() {
    cat <<'EOF'
Usage: claude-usage.sh [--file CACHE.json] [--live]

Shows Claude 7-day usage from the Raycast Claude Usage extension cache:
  - default: 7-day quota pace only, e.g. "7d 42% reset 5d12h · +3% spare"
  - --live, --watch: refresh every minute until interrupted
EOF
}

cache_file=''
live_output='0'
render_args=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --file)
            render_args+=("$1")
            shift
            cache_file="${1:-}"
            render_args+=("$cache_file")
            ;;
        --live|--watch)
            live_output='1'
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf "Unknown argument: %s\n" "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

if [ "$live_output" = "1" ]; then
    interval="${CLAUDE_USAGE_LIVE_INTERVAL_SECONDS:-60}"
    while true; do
        clear
        bash "$0" ${render_args[@]+"${render_args[@]}"}
        printf "\nrefreshes every %ss; press Ctrl-C to stop\n" "$interval"
        sleep "$interval"
    done
fi

if ! command -v jq >/dev/null 2>&1; then
    printf "jq is required to parse the Claude usage cache\n" >&2
    exit 1
fi

path_cache="$HOME/.claude/state/seven-day-usage-cache-path"
if [ -z "$cache_file" ] && [ -f "$path_cache" ]; then
    candidate=$(cat "$path_cache" 2>/dev/null)
    if [ -n "$candidate" ] && [ -f "$candidate" ] && head -c 80 "$candidate" 2>/dev/null | grep -q 'seven_day'; then
        cache_file="$candidate"
    fi
fi

if [ -z "$cache_file" ]; then
    raycast_root="$HOME/Library/Application Support/com.raycast.macos/extensions"
    if [ -d "$raycast_root" ]; then
        for candidate in "$raycast_root"/*/com.raycast.api.cache/*; do
            [ -f "$candidate" ] || continue
            if head -c 160 "$candidate" 2>/dev/null | grep -q 'seven_day'; then
                cache_file="$candidate"
                mkdir -p "$(dirname "$path_cache")"
                printf "%s" "$candidate" > "$path_cache"
                break
            fi
        done
    fi
fi

if [ -z "$cache_file" ] || [ ! -f "$cache_file" ]; then
    printf "No Claude usage cache found. Open or refresh the Raycast Claude Usage extension first.\n" >&2
    exit 1
fi

util=$(jq -r '.seven_day.utilization // empty' "$cache_file" 2>/dev/null)
reset=$(jq -r '.seven_day.resets_at // empty' "$cache_file" 2>/dev/null)
if [ -z "$util" ] || [ -z "$reset" ]; then
    printf "No 7-day Claude usage data found in %s\n" "$cache_file" >&2
    exit 1
fi

stale='0'
if find "$cache_file" -mmin +30 2>/dev/null | grep -q .; then
    stale='1'
fi

rendered=$(UTIL="$util" RESET="$reset" STALE="$stale" python3 - <<'PYEOF'
import os
from datetime import datetime, timezone

util = float(os.environ["UTIL"])
reset = datetime.fromisoformat(os.environ["RESET"].replace("Z", "+00:00"))
stale = os.environ.get("STALE") == "1"

now = datetime.now(timezone.utc)
window_h = 7 * 24
hours_left = max(0.0, (reset - now).total_seconds() / 3600.0)
progress = max(0.0, min(100.0, (window_h - hours_left) / window_h * 100.0))
projected = (util / progress * 100.0) if progress > 1 else util
diff = util - progress

if projected >= 100 and progress > 5:
    fg = "38;5;196"
    label = "over pace"
elif diff < -1:
    fg = "38;5;34"
    label = f"+{int(round(-diff))}% spare"
elif diff > 1:
    fg = "38;5;208"
    label = f"-{int(round(diff))}% over"
else:
    fg = "38;5;220"
    label = "on track"

if stale:
    fg = "38;5;245"

days = int(hours_left // 24)
hours = int(hours_left % 24)
if days:
    reset_text = f"{days}d{hours:02d}h"
else:
    minutes = int((hours_left % 1) * 60)
    reset_text = f"{hours}h{minutes:02d}m"

chunk = f"7d {int(round(util))}% reset {reset_text} · {label}"
if os.environ.get("NO_COLOR"):
    print(chunk, end="")
else:
    print(f"\033[{fg}m{chunk}\033[0m", end="")
PYEOF
)

printf "%s\n" "$rendered"
