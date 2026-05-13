#!/bin/bash
set -euo pipefail

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

fixture="$tmp_dir/session.jsonl"
now=$(date +%s)
primary_reset=$((now + 3600))
secondary_reset=$((now + 5 * 24 * 3600 + 12 * 3600))

cat >"$fixture" <<EOF
{"timestamp":"2026-05-13T09:00:00.000Z","type":"session_meta","payload":{"id":"test-session","cwd":"/tmp/codex-project","model_provider":"openai"}}
{"timestamp":"2026-05-13T09:00:01.000Z","type":"turn_context","payload":{"cwd":"/tmp/codex-project","model":"gpt-5.5","effort":{"level":"high"}}}
{"timestamp":"2026-05-13T09:00:02.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[]}}
{"timestamp":"2026-05-13T09:00:03.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20000,"cached_input_tokens":5000,"output_tokens":3000,"reasoning_output_tokens":1000,"total_tokens":23000},"last_token_usage":{"input_tokens":10000,"cached_input_tokens":1000,"output_tokens":1000,"reasoning_output_tokens":500,"total_tokens":11000},"model_context_window":100000},"rate_limits":{"primary":{"used_percent":42.4,"window_minutes":300,"resets_at":$primary_reset},"secondary":{"used_percent":4.2,"window_minutes":10080,"resets_at":$secondary_reset},"credits":null,"plan_type":"pro","rate_limit_reached_type":null}}}
EOF

output=$(NO_COLOR=1 bash ./codex-usage.sh --file "$fixture")

grep -q '7d 4%' <<<"$output"
grep -q '+17% spare' <<<"$output"

full_output=$(NO_COLOR=1 bash ./codex-usage.sh --full --file "$fixture")

grep -q '11% ctx' <<<"$full_output"
grep -q 'gpt-5.5' <<<"$full_output"
grep -q 'high' <<<"$full_output"
grep -q '5h 42%' <<<"$full_output"
grep -q '7d 4%' <<<"$full_output"
grep -q 'Σ 23.0k tok' <<<"$full_output"
grep -q 'last 11.0k' <<<"$full_output"
grep -q 'in 20.0k cached 5.0k out 3.0k think 1.0k' <<<"$full_output"
grep -q 'msgs 1 | pro | codex-project' <<<"$full_output"

printf "codex-usage fixture test passed\n"
