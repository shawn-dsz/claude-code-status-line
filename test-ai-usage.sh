#!/bin/bash
set -euo pipefail

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

codex_fixture="$tmp_dir/session.jsonl"
claude_fixture="$tmp_dir/claude-usage.json"
now=$(date +%s)
primary_reset=$((now + 3600))
secondary_reset=$((now + 5 * 24 * 3600 + 12 * 3600))
claude_reset=$(python3 - <<'PYEOF'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) + timedelta(days=5, hours=12)).isoformat().replace("+00:00", "Z"))
PYEOF
)

cat >"$codex_fixture" <<EOF
{"timestamp":"2026-05-13T09:00:00.000Z","type":"session_meta","payload":{"id":"test-session","cwd":"/tmp/codex-project","model_provider":"openai"}}
{"timestamp":"2026-05-13T09:00:01.000Z","type":"turn_context","payload":{"cwd":"/tmp/codex-project","model":"gpt-5.5","effort":{"level":"high"}}}
{"timestamp":"2026-05-13T09:00:02.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[]}}
{"timestamp":"2026-05-13T09:00:03.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20000,"cached_input_tokens":5000,"output_tokens":3000,"reasoning_output_tokens":1000,"total_tokens":23000},"last_token_usage":{"input_tokens":10000,"cached_input_tokens":1000,"output_tokens":1000,"reasoning_output_tokens":500,"total_tokens":11000},"model_context_window":100000},"rate_limits":{"primary":{"used_percent":42.4,"window_minutes":300,"resets_at":$primary_reset},"secondary":{"used_percent":4.2,"window_minutes":10080,"resets_at":$secondary_reset},"credits":null,"plan_type":"pro","rate_limit_reached_type":null}}}
EOF
printf '{"seven_day":{"utilization":28.2,"resets_at":"%s"}}\n' "$claude_reset" >"$claude_fixture"

output=$(NO_COLOR=1 bash ./ai-usage.sh --codex-file "$codex_fixture" --claude-file "$claude_fixture")

grep -q '^codex  ' <<<"$output"
grep -q '^claude ' <<<"$output"
grep -q 'codex  .*4% · +17% spare' <<<"$output"
grep -q 'claude .*28% ·' <<<"$output"

live_output="$tmp_dir/live-output.txt"
TERM=xterm NO_COLOR=1 AI_USAGE_LIVE_INTERVAL_SECONDS=1 bash ./ai-usage.sh --live --codex-file "$codex_fixture" --claude-file "$claude_fixture" >"$live_output" &
live_pid=$!
sleep 1.2
kill "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true

grep -q 'codex  ' "$live_output"
grep -q 'claude ' "$live_output"
grep -q 'refreshes every 1s' "$live_output"

printf "ai-usage fixture test passed\n"
