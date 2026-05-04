#!/bin/bash
# Status line script for Claude Code
# Displays: context_health | duration | model | output_style | effort | project_dir | git_branch | git_status | files | lines

input=$(cat)
model=$(echo "$input" | jq -r '.model.display_name')
output_style=$(echo "$input" | jq -r '.output_style.name')
project_dir=$(echo "$input" | jq -r '.workspace.project_dir')
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')

# Session identity
session_id=$(echo "$input" | jq -r '.session_id // empty')
agent_display=''
instance_display=''
identity_file="$HOME/.claude/state/current-session-identity.json"
agent_colour=''
agent_emoji='◆'
agent_name=''
if [ -f "$identity_file" ]; then
    agent_name=$(jq -r '.agent_name // empty' "$identity_file" 2>/dev/null)
    agent_colour=$(jq -r '.color // empty' "$identity_file" 2>/dev/null)
    file_emoji=$(jq -r '.emoji // empty' "$identity_file" 2>/dev/null)
    [ -n "$file_emoji" ] && agent_emoji="$file_emoji"
fi
case "$agent_colour" in
    red)    agent_ansi='\033[1;38;5;196m' ;;
    blue)   agent_ansi='\033[1;38;5;39m'  ;;
    green)  agent_ansi='\033[1;38;5;34m'  ;;
    yellow) agent_ansi='\033[1;38;5;220m' ;;
    purple) agent_ansi='\033[1;38;5;135m' ;;
    orange) agent_ansi='\033[1;38;5;208m' ;;
    pink)   agent_ansi='\033[1;38;5;205m' ;;
    cyan)   agent_ansi='\033[1;38;5;51m'  ;;
    *)      agent_ansi='\033[1m'          ;;
esac
# Agent name for line 1
if [ -n "$agent_name" ]; then
    agent_display=$(printf "${agent_ansi}%s %s\033[0m" "$agent_emoji" "$agent_name")
fi
# Short instance ID for line 2
if [ -n "$session_id" ]; then
    short_id="${session_id:0:8}"
    instance_display=$(printf "${agent_ansi}%s\033[0m" "$short_id")
fi

# Reasoning effort (may appear at top level or nested; default based on model)
reasoning_effort=$(echo "$input" | jq -r '.effort.level // .reasoning_effort // .model.reasoning_effort // .output_style.reasoning_effort // empty')
if [ -z "$reasoning_effort" ]; then
    # Default effort based on model
    model_lower=$(echo "$model" | tr '[:upper:]' '[:lower:]')
    case "$model_lower" in
        *opus*|*sonnet*) reasoning_effort='high' ;;
        *haiku*)         reasoning_effort='medium' ;;
        *)               reasoning_effort='medium' ;;
    esac
fi
case "$reasoning_effort" in
    none)    effort_display=$(printf "\033[38;5;245m∅ none\033[0m") ;;  # grey - off
    minimal) effort_display=$(printf "\033[36m⚡min\033[0m") ;;          # cyan - minimal
    low)     effort_display=$(printf "\033[32m⚡low\033[0m") ;;          # green - fast
    medium)  effort_display=$(printf "\033[33m⚙ med\033[0m") ;;         # yellow - balanced
    high)    effort_display=$(printf "\033[35m🧠high\033[0m") ;;         # magenta - deep
    xhigh)   effort_display=$(printf "\033[1;35m🧠xhigh\033[0m") ;;      # bold magenta - deeper
    max)     effort_display=$(printf "\033[1;31m🧠max\033[0m") ;;        # bold red - deepest
    *)       effort_display=$(printf "\033[38;5;245m⚙ %s\033[0m" "$reasoning_effort") ;;  # grey - unknown
esac

# Context window gauge
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
window_size=$(echo "$input" | jq -r '.context_window.context_window_size // empty')

# Derive canonical window size from model name; correct stale values from Claude Code
model_lower=$(echo "$model" | tr '[:upper:]' '[:lower:]')
case "$model_lower" in
    *opus*)    canonical_window=1000000 ;;
    *sonnet*)  canonical_window=200000  ;;
    *haiku*)   canonical_window=200000  ;;
    *gemini*)  canonical_window=2000000 ;;
    *)         canonical_window=""      ;;
esac
# Use canonical size unconditionally when known -- ensures model switches are reflected immediately
if [ -n "$canonical_window" ]; then
    window_size=$canonical_window
fi

# Calculate total tokens used in context (sum of all current_usage token fields)
input_tokens=$(echo "$input" | jq -r '
    .context_window.current_usage |
    ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0) + (.output_tokens // 0))
')
[ "$input_tokens" = "null" ] || [ "$input_tokens" = "0" ] && {
    # Fallback to total_input_tokens if current_usage sum is zero
    input_tokens=$(echo "$input" | jq -r '.context_window.total_input_tokens // empty')
}

# Recalculate percentage using the authoritative window size
if [ -n "$window_size" ] && [ -n "$input_tokens" ] && [ "$input_tokens" != "0" ]; then
    used_pct=$(( (input_tokens * 100) / window_size ))
fi

ctx_gauge=''
if [ -n "$used_pct" ] && [ -n "$window_size" ]; then
    # Dial icon based on health zone
    if [ "$used_pct" -lt 30 ]; then
        dial='◔'
    elif [ "$used_pct" -lt 60 ]; then
        dial='◑'
    else
        dial='●'
    fi

    # Heat gradient and health hint based on context usage
    if [ "$used_pct" -lt 15 ]; then
        colour='\033[38;5;34m'    # green - plenty of room
        health_hint=''
    elif [ "$used_pct" -lt 30 ]; then
        colour='\033[38;5;112m'   # light green - healthy
        health_hint=''
    elif [ "$used_pct" -lt 45 ]; then
        colour='\033[38;5;220m'   # yellow - getting warm
        health_hint=' ⚠ compact soon'
    elif [ "$used_pct" -lt 60 ]; then
        colour='\033[38;5;208m'   # orange - consider compacting
        health_hint=' ⚠ compact soon'
    elif [ "$used_pct" -lt 75 ]; then
        colour='\033[38;5;196m'   # red - compact now
        health_hint=' 🛑 compact now'
    else
        colour='\033[38;5;160m'   # dark red - critical
        health_hint=' 🛑 compact or new chat'
    fi
    reset='\033[0m'

    # Filled brick bar (10 blocks: █ filled, ░ empty)
    filled=$(( (used_pct * 10 + 50) / 100 ))
    [ "$filled" -lt 0 ] && filled=0
    [ "$filled" -gt 10 ] && filled=10
    bar=''
    i=1
    while [ "$i" -le 10 ]; do
        if [ "$i" -le "$filled" ]; then
            bar="${bar}█"
        else
            bar="${bar}░"
        fi
        i=$((i + 1))
    done

    # Compact token display (e.g. 98k/200k)
    token_display=''
    if [ -n "$input_tokens" ] && [ "$input_tokens" != "0" ]; then
        if [ "$input_tokens" -ge 1000000 ]; then
            used_display="$(( input_tokens / 1000000 )).$(( (input_tokens % 1000000) / 100000 ))M"
        elif [ "$input_tokens" -ge 1000 ]; then
            used_display="$(( input_tokens / 1000 ))k"
        else
            used_display="$input_tokens"
        fi

        if [ "$window_size" -ge 1000000 ]; then
            total_display="$(( window_size / 1000000 )).$(( (window_size % 1000000) / 100000 ))M"
        elif [ "$window_size" -ge 1000 ]; then
            total_display="$(( window_size / 1000 ))k"
        else
            total_display="$window_size"
        fi
        token_display=" ${used_display}/${total_display}"
    fi

    ctx_gauge=$(printf "${colour}${bar} ${used_pct}%%${token_display}${health_hint}${reset}")
fi

# Session duration
duration_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // empty')
duration_display=''
if [ -n "$duration_ms" ] && [ "$duration_ms" != "0" ]; then
    total_secs=$(( duration_ms / 1000 ))
    hours=$(( total_secs / 3600 ))
    mins=$(( (total_secs % 3600) / 60 ))
    secs=$(( total_secs % 60 ))
    if [ "$hours" -gt 0 ]; then
        duration_display=$(printf "\033[38;5;245m%dh%02dm\033[0m" "$hours" "$mins")
    elif [ "$mins" -gt 0 ]; then
        duration_display=$(printf "\033[38;5;245m%dm%02ds\033[0m" "$mins" "$secs")
    else
        duration_display=$(printf "\033[38;5;245m%ds\033[0m" "$secs")
    fi
fi

git_branch=''
git_status=''
files_changed=''
lines_changed=''

if git -C "$project_dir" rev-parse --git-dir > /dev/null 2>&1; then
    git_branch=$(git -C "$project_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
    git_output=$(git -C "$project_dir" --no-optional-locks status --porcelain 2>/dev/null)

    if [ -z "$git_output" ]; then
        git_status='clean'
        files_changed='0'
    else
        git_status='dirty'
        files_changed=$(echo "$git_output" | wc -l | tr -d ' ')
    fi

    diff_stat=$(git -C "$project_dir" --no-optional-locks diff --numstat 2>/dev/null | awk '{added+=$1; deleted+=$2} END {print "+"added"/-"deleted}')
    if [ -z "$diff_stat" ] || [ "$diff_stat" = '+/-' ]; then
        lines_changed='+0/-0'
    else
        lines_changed="$diff_stat"
    fi
fi

# Line 1: context gauge | model | effort | agent
line1=''

if [ -n "$ctx_gauge" ]; then
    line1="${ctx_gauge}"
fi

[ -n "$line1" ] && line1="${line1} | "
line1=$(printf "%s\033[36m%s\033[0m" "$line1" "$model")

if [ -n "$effort_display" ]; then
    line1=$(printf "%s | %s" "$line1" "$effort_display")
fi

if [ -n "$agent_display" ]; then
    [ -n "$line1" ] && line1="${line1} | "
    line1="${line1}${agent_display}"
fi

# Line 2: git branch | files | lines | duration | cost | instance_id
line2=''

if [ -n "$git_branch" ]; then
    line2=$(printf "\033[38;5;245m%s\033[0m" "$git_branch")
fi

if [ -n "$files_changed" ]; then
    # Heat gradient: green (0 files) -> yellow -> orange -> red (10+ files)
    if [ "$files_changed" -eq 0 ]; then
        file_colour='\033[38;5;34m'    # green
    elif [ "$files_changed" -le 2 ]; then
        file_colour='\033[38;5;112m'   # light green
    elif [ "$files_changed" -le 4 ]; then
        file_colour='\033[38;5;220m'   # yellow
    elif [ "$files_changed" -le 6 ]; then
        file_colour='\033[38;5;208m'   # orange
    elif [ "$files_changed" -le 9 ]; then
        file_colour='\033[38;5;196m'   # red
    else
        file_colour='\033[38;5;160m'   # dark red
    fi
    [ -n "$line2" ] && line2="${line2} | "
    line2=$(printf "%s${file_colour}%s files\033[0m \033[36m%s\033[0m" "$line2" "$files_changed" "$lines_changed")
fi

if [ -n "$duration_display" ]; then
    [ -n "$line2" ] && line2="${line2} | "
    line2="${line2}${duration_display}"
fi

# Message count: count actual human prompts (string content, non-sidechain, external)
# from the session transcript provided by Claude Code
msg_count=''
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ] && command -v python3 >/dev/null 2>&1; then
    msg_count=$(python3 -c "
import json, sys
count = 0
try:
    with open('$transcript_path') as f:
        for line in f:
            try:
                obj = json.loads(line)
                if (obj.get('type') == 'user' and
                    obj.get('userType') == 'external' and
                    not obj.get('isSidechain', False) and
                    isinstance(obj.get('message', {}).get('content', ''), str)):
                    count += 1
            except Exception:
                pass
except Exception:
    pass
print(count)
" 2>/dev/null)
fi
if [[ "$msg_count" =~ ^[0-9]+$ ]] && [ "$msg_count" -gt 0 ]; then
    [ -n "$line2" ] && line2="${line2} | "
    line2=$(printf "%s\033[38;5;245m💬%s\033[0m" "$line2" "$msg_count")
fi

# Last response time: find most recent assistant message timestamp and show local time
last_heard=''
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ] && command -v python3 >/dev/null 2>&1; then
    last_heard=$(python3 -c "
import json, sys
from datetime import datetime, timezone
last_ts = None
try:
    with open('$transcript_path') as f:
        for line in f:
            try:
                obj = json.loads(line)
                if obj.get('type') == 'assistant' and obj.get('timestamp'):
                    last_ts = obj['timestamp']
            except Exception:
                pass
except Exception:
    pass
if last_ts:
    try:
        dt = datetime.fromisoformat(last_ts.replace('Z', '+00:00'))
        local_dt = dt.astimezone()
        print(local_dt.strftime('%-I:%M%p').lower())
    except Exception:
        pass
" 2>/dev/null)
fi
if [ -n "$last_heard" ]; then
    [ -n "$line2" ] && line2="${line2} | "
    line2=$(printf "%s\033[38;5;245m🕐%s\033[0m" "$line2" "$last_heard")
fi

# Session cost
session_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
if [ -n "$session_cost" ] && [ "$session_cost" != "0" ]; then
    usd_to_aud=1.42
    session_cost_aud=$(printf "%.2f" "$(echo "$session_cost * $usd_to_aud" | bc)")
    [ -n "$line2" ] && line2="${line2} | "
    line2=$(printf "%s\033[33mA\$%s\033[0m" "$line2" "$session_cost_aud")
fi

if [ -n "$instance_display" ]; then
    [ -n "$line2" ] && line2="${line2} | "
    line2="${line2}${instance_display}"
fi

printf "%s\n%s\n" "$line1" "$line2"
