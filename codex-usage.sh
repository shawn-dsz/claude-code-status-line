#!/bin/bash
# Usage tracker for Codex Desktop/CLI session JSONL.

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
Usage: codex-usage.sh [--file SESSION.jsonl] [--latest] [--full] [--live]

Shows current Codex usage from Codex session JSONL:
  - default: 7-day quota pace only, e.g. "▓▓▓░│░░░░░ 28% · +14% spare"
  - --full: model, effort, 5-hour quota, tokens, messages, and workspace
  - --live, --watch: refresh every minute until interrupted
EOF
}

session_file=''
full_output='0'
live_output='0'
render_args=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --file)
            render_args+=("$1")
            shift
            session_file="${1:-}"
            render_args+=("$session_file")
            ;;
        --latest)
            session_file=''
            render_args+=("$1")
            ;;
        --full)
            full_output='1'
            render_args+=("$1")
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
    interval="${CODEX_USAGE_LIVE_INTERVAL_SECONDS:-60}"
    while true; do
        clear
        bash "$0" ${render_args[@]+"${render_args[@]}"}
        printf "\nrefreshes every %ss; press Ctrl-C to stop\n" "$interval"
        sleep "$interval"
    done
fi

if [ -z "$session_file" ]; then
    session_file=$(find "$HOME/.codex/sessions" -type f -name 'rollout-*.jsonl' -print0 2>/dev/null |
        xargs -0 ls -t 2>/dev/null |
        head -n1 || true)
fi

if [ -z "$session_file" ] || [ ! -f "$session_file" ]; then
    printf "No Codex session JSONL found. Try --file /path/to/session.jsonl\n" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    printf "jq is required to parse Codex session JSONL\n" >&2
    exit 1
fi

last_token_payload=$(jq -c 'select(.type == "event_msg" and .payload.type == "token_count") | .payload' "$session_file" | tail -n1)
if [ -z "$last_token_payload" ]; then
    printf "No token_count events found in %s\n" "$session_file" >&2
    exit 1
fi

rate_limit_payload=$(jq -c 'select(.type == "event_msg" and .payload.type == "token_count" and .payload.rate_limits) | .payload' "$session_file" | tail -n1)
[ -z "$rate_limit_payload" ] && rate_limit_payload="$last_token_payload"

if ! jq -e '(.rate_limits.primary.used_percent? != null) or (.rate_limits.secondary.used_percent? != null)' >/dev/null 2>&1 <<<"$rate_limit_payload"; then
    while IFS= read -r candidate; do
        candidate_payload=$(jq -c 'select(.type == "event_msg" and .payload.type == "token_count" and ((.payload.rate_limits.primary.used_percent? != null) or (.payload.rate_limits.secondary.used_percent? != null))) | .payload' "$candidate" 2>/dev/null | tail -n1)
        if [ -n "$candidate_payload" ]; then
            rate_limit_payload="$candidate_payload"
            break
        fi
    done < <(find "$HOME/.codex/sessions" -type f -name 'rollout-*.jsonl' -exec stat -f '%m %N' {} + 2>/dev/null |
        sort -rn |
        head -25 |
        cut -d' ' -f2-)
fi

last_context=$(jq -c 'select(.type == "turn_context") | .payload' "$session_file" | tail -n1)
session_meta=$(jq -c 'select(.type == "session_meta") | .payload' "$session_file" | tail -n1)

jq_payload() {
    jq -r "$1 // empty" <<<"$last_token_payload"
}

jq_rate_limit() {
    jq -r "$1 // empty" <<<"$rate_limit_payload"
}

jq_context() {
    if [ -n "$last_context" ]; then
        jq -r "$1 // empty" <<<"$last_context"
    fi
}

jq_meta() {
    if [ -n "$session_meta" ]; then
        jq -r "$1 // empty" <<<"$session_meta"
    fi
}

fmt_number() {
    local value="${1:-0}"
    awk -v n="$value" 'BEGIN {
        if (n >= 1000000) printf "%.1fm", n / 1000000;
        else if (n >= 1000) printf "%.1fk", n / 1000;
        else printf "%d", n;
    }'
}

fmt_pct() {
    local value="${1:-0}"
    awk -v n="$value" 'BEGIN { printf "%d", n + 0.5 }'
}

fmt_reset() {
    local epoch="$1"
    [ -n "$epoch" ] || return 0
    python3 - "$epoch" <<'PYEOF' 2>/dev/null || true
import sys, time
epoch = int(float(sys.argv[1]))
delta = max(0, epoch - int(time.time()))
days, rem = divmod(delta, 86400)
hours, rem = divmod(rem, 3600)
mins = rem // 60
if days:
    print(f"{days}d{hours:02d}h")
elif hours:
    print(f"{hours}h{mins:02d}m")
else:
    print(f"{mins}m")
PYEOF
}

quota_chunk() {
    local label="$1"
    local pct="$2"
    local reset_epoch="$3"
    local window_minutes="$4"
    [ -n "$pct" ] || return 0

    local rounded colour_code rendered
    rounded=$(fmt_pct "$pct")

    if [ "$rounded" -lt 50 ]; then
        colour_code='38;5;34'
    elif [ "$rounded" -lt 75 ]; then
        colour_code='38;5;220'
    elif [ "$rounded" -lt 90 ]; then
        colour_code='38;5;208'
    else
        colour_code='38;5;196'
    fi

    if [ "$window_minutes" = "10080" ] && [ -n "$reset_epoch" ]; then
        rendered=$(python3 - "$pct" "$reset_epoch" <<'PYEOF' 2>/dev/null || true
import sys, time
used = float(sys.argv[1])
reset = int(float(sys.argv[2]))
window = 7 * 24 * 3600
elapsed = max(0, min(window, window - max(0, reset - int(time.time()))))
pace = elapsed / window * 100 if window else 0
diff = used - pace
projected = used / pace * 100 if pace > 1 else used
cells = 10
filled = max(0, min(cells, int(round(used / 100 * cells))))
pace_mark = max(0, min(cells - 1, int(round(pace / 100 * cells))))
bar = []
for i in range(cells):
    if i < filled:
        bar.append("▓")
    elif i == pace_mark:
        bar.append("│")
    else:
        bar.append("░")
if projected >= 100 and pace > 5:
    label = "over pace"
elif diff < -1:
    label = f"+{round(-diff):.0f}% spare"
elif diff > 1:
    label = f"-{round(diff):.0f}% over"
else:
    label = "on track"
print(f"{''.join(bar)} {int(round(used))}% · {label}")
PYEOF
)
    else
        rendered=$(python3 - "$pct" <<'PYEOF' 2>/dev/null || true
import sys
used = float(sys.argv[1])
cells = 10
filled = max(0, min(cells, int(round(used / 100 * cells))))
bar = "▓" * filled + "░" * (cells - filled)
print(f"{bar} {int(round(used))}%")
PYEOF
)
    fi

    colour "$colour_code" "$rendered"
}

model=$(jq_context '.model')
effort=$(jq_context 'if (.effort | type) == "object" then .effort.level else .effort end')
cwd=$(jq_context '.cwd')
[ -z "$model" ] && model=$(jq_meta '.model // .model_provider')
[ -z "$cwd" ] && cwd=$(jq_meta '.cwd')
[ -z "$effort" ] && effort=$(jq_meta '.model_reasoning_effort')
[ -z "$effort" ] && effort='medium'

total_tokens=$(jq_payload '.info.total_token_usage.total_tokens')
input_tokens=$(jq_payload '.info.total_token_usage.input_tokens')
cached_tokens=$(jq_payload '.info.total_token_usage.cached_input_tokens')
output_tokens=$(jq_payload '.info.total_token_usage.output_tokens')
reasoning_tokens=$(jq_payload '.info.total_token_usage.reasoning_output_tokens')
last_tokens=$(jq_payload '.info.last_token_usage.total_tokens')
context_window=$(jq_payload '.info.model_context_window')

ctx_pct=''
context_tokens="$last_tokens"
[ -z "$context_tokens" ] && context_tokens="$total_tokens"
if [ -n "$context_tokens" ] && [ -n "$context_window" ] && [ "$context_window" != "0" ]; then
    ctx_pct=$(awk -v used="$context_tokens" -v window="$context_window" 'BEGIN { printf "%d", (used / window * 100) + 0.5 }')
fi

primary_pct=$(jq_rate_limit '.rate_limits.primary.used_percent')
primary_reset=$(jq_rate_limit '.rate_limits.primary.resets_at')
primary_window=$(jq_rate_limit '.rate_limits.primary.window_minutes')
secondary_pct=$(jq_rate_limit '.rate_limits.secondary.used_percent')
secondary_reset=$(jq_rate_limit '.rate_limits.secondary.resets_at')
secondary_window=$(jq_rate_limit '.rate_limits.secondary.window_minutes')
plan_type=$(jq_rate_limit '.rate_limits.plan_type')
limit_reached=$(jq_rate_limit '.rate_limits.rate_limit_reached_type')

secondary_chunk=$(quota_chunk '7d' "$secondary_pct" "$secondary_reset" "$secondary_window")
if [ "$full_output" != "1" ]; then
    if [ -z "$secondary_chunk" ]; then
        printf "No 7-day Codex quota data found\n" >&2
        exit 1
    fi
    printf "%s\n" "$secondary_chunk"
    exit 0
fi

messages=$(jq -r 'select(.type == "response_item" and .payload.type == "message" and .payload.role == "user") | .payload.role' "$session_file" | wc -l | tr -d ' ')
workspace=$(basename "$cwd" 2>/dev/null || true)
[ -z "$workspace" ] && workspace='unknown'

case "$effort" in
    none|minimal) effort_display=$(colour '38;5;245' "$effort") ;;
    low) effort_display=$(colour '38;5;34' 'low') ;;
    medium) effort_display=$(colour '38;5;220' 'medium') ;;
    high|xhigh|max) effort_display=$(colour '38;5;201' "$effort") ;;
    *) effort_display=$(colour '38;5;245' "$effort") ;;
esac

line1=''
if [ -n "$ctx_pct" ]; then
    if [ "$ctx_pct" -lt 35 ]; then
        ctx_colour='38;5;34'
        dial='◔'
    elif [ "$ctx_pct" -lt 70 ]; then
        ctx_colour='38;5;220'
        dial='◑'
    else
        ctx_colour='38;5;196'
        dial='●'
    fi
    line1=$(colour "$ctx_colour" "${dial} ${ctx_pct}% ctx")
fi

[ -n "$line1" ] && line1="${line1} | "
line1="${line1}$(colour '36' "$model") | ${effort_display}"

primary_chunk=$(quota_chunk '5h' "$primary_pct" "$primary_reset" "$primary_window")
[ -n "$primary_chunk" ] && line1="${line1} | ${primary_chunk}"
[ -n "$secondary_chunk" ] && line1="${line1} | ${secondary_chunk}"
if [ -n "$limit_reached" ] && [ "$limit_reached" != "null" ]; then
    line1="${line1} | $(colour '38;5;196' "limited: ${limit_reached}")"
fi

line2=''
if [ -n "$total_tokens" ]; then
    line2="Σ $(fmt_number "$total_tokens") tok"
fi
if [ -n "$last_tokens" ]; then
    [ -n "$line2" ] && line2="${line2} | "
    line2="${line2}last $(fmt_number "$last_tokens")"
fi
if [ -n "$input_tokens" ] || [ -n "$output_tokens" ] || [ -n "$reasoning_tokens" ]; then
    [ -n "$line2" ] && line2="${line2} | "
    line2="${line2}in $(fmt_number "${input_tokens:-0}")"
    [ -n "$cached_tokens" ] && line2="${line2} cached $(fmt_number "$cached_tokens")"
    line2="${line2} out $(fmt_number "${output_tokens:-0}") think $(fmt_number "${reasoning_tokens:-0}")"
fi
[ -n "$line2" ] && line2="${line2} | "
line2="${line2}msgs ${messages} | ${plan_type:-unknown} | ${workspace}"

printf "%s\n%s\n" "$line1" "$line2"
