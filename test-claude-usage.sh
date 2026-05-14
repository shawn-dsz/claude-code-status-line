#!/bin/bash
set -euo pipefail

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

fixture="$tmp_dir/claude-usage.json"
reset=$(python3 - <<'PYEOF'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) + timedelta(days=5, hours=12)).isoformat().replace("+00:00", "Z"))
PYEOF
)

printf '{"seven_day":{"utilization":4.2,"resets_at":"%s"}}\n' "$reset" >"$fixture"

output=$(NO_COLOR=1 bash ./claude-usage.sh --file "$fixture")

grep -q '7d 4%' <<<"$output"
grep -q 'reset 5d' <<<"$output"
grep -q '+17% spare' <<<"$output"

live_output="$tmp_dir/live-output.txt"
TERM=xterm NO_COLOR=1 CLAUDE_USAGE_LIVE_INTERVAL_SECONDS=1 bash ./claude-usage.sh --live --file "$fixture" >"$live_output" &
live_pid=$!
sleep 0.3
kill "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true

grep -q '7d 4%' "$live_output"
grep -q 'refreshes every 1s' "$live_output"

printf "claude-usage fixture test passed\n"
