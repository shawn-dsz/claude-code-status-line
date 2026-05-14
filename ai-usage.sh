#!/bin/bash
# Combined usage tracker for Codex and Claude.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ai-usage.sh [--live] [--codex-file SESSION.jsonl] [--claude-file CACHE.json]

Shows Codex and Claude 7-day usage bars:
  codex  ▓▓░│░░░░░░ 24% · +7% spare
  claude ▓▓▓░│░░░░░ 28% · +14% spare

Options:
  --live, --watch          refresh every minute until interrupted
  --codex-file FILE        read Codex usage from a specific session JSONL
  --claude-file FILE       read Claude usage from a specific Raycast cache JSON
EOF
}

root_dir=$(cd "$(dirname "$0")" && pwd)
codex_file=''
claude_file=''
live_output='0'
render_args=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --codex-file)
            render_args+=("$1")
            shift
            codex_file="${1:-}"
            render_args+=("$codex_file")
            ;;
        --claude-file)
            render_args+=("$1")
            shift
            claude_file="${1:-}"
            render_args+=("$claude_file")
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
    interval="${AI_USAGE_LIVE_INTERVAL_SECONDS:-60}"
    active_pid=''
    stop_live() {
        if [ -n "$active_pid" ]; then
            kill "$active_pid" 2>/dev/null || true
        fi
        exit 130
    }
    trap stop_live INT TERM
    while true; do
        clear
        bash "$0" ${render_args[@]+"${render_args[@]}"} &
        active_pid=$!
        wait "$active_pid"
        active_pid=''
        printf "\nrefreshes every %ss; press Ctrl-C to stop\n" "$interval"
        sleep "$interval" &
        active_pid=$!
        wait "$active_pid"
        active_pid=''
    done
fi

run_codex() {
    if [ -n "$codex_file" ]; then
        bash "$root_dir/codex-usage.sh" --file "$codex_file"
    else
        bash "$root_dir/codex-usage.sh"
    fi
}

run_claude() {
    if [ -n "$claude_file" ]; then
        bash "$root_dir/claude-usage.sh" --file "$claude_file"
    else
        bash "$root_dir/claude-usage.sh"
    fi
}

codex_output=$(run_codex 2>&1) || codex_output="unavailable · ${codex_output}"
claude_output=$(run_claude 2>&1) || claude_output="unavailable · ${claude_output}"

printf "codex  %s\n" "$codex_output"
printf "claude %s\n" "$claude_output"
