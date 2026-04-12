#!/bin/bash
# Status line script for Claude Code
# Displays: context_health | duration | model | output_style | effort | project_dir | git_branch | git_status | files | lines

input=$(cat)
model=$(echo "$input" | jq -r '.model.display_name')
output_style=$(echo "$input" | jq -r '.output_style.name')
project_dir=$(echo "$input" | jq -r '.workspace.project_dir')

# Session agent identity (set by ~/.claude/hooks.global/session-identity.sh)
agent_name=''
agent_display=''
identity_file="$HOME/.claude/state/current-session-identity.json"
if [ -f "$identity_file" ]; then
    agent_name=$(jq -r '.agent_name // empty' "$identity_file" 2>/dev/null)
    agent_colour=$(jq -r '.color // empty' "$identity_file" 2>/dev/null)
    agent_emoji=$(jq -r '.emoji // empty' "$identity_file" 2>/dev/null)
    [ -z "$agent_emoji" ] && agent_emoji='◆'
    if [ -n "$agent_name" ]; then
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
        agent_display=$(printf "${agent_ansi}%s %s\033[0m" "$agent_emoji" "$agent_name")
    fi
fi

# Reasoning effort (may appear at top level or nested; default based on model)
reasoning_effort=$(echo "$input" | jq -r '.reasoning_effort // .model.reasoning_effort // .output_style.reasoning_effort // empty')
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
    low)    effort_display=$(printf "\033[32m⚡low\033[0m") ;;    # green - fast
    medium) effort_display=$(printf "\033[33m⚙ med\033[0m") ;;   # yellow - balanced
    high)   effort_display=$(printf "\033[35m🧠high\033[0m") ;;   # magenta - deep
    *)      effort_display=$(printf "\033[38;5;245m⚙ %s\033[0m" "$reasoning_effort") ;;  # grey - unknown
esac

# Context window gauge
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
window_size=$(echo "$input" | jq -r '.context_window.context_window_size // empty')

# Override known context window sizes when Claude Code reports stale values
model_lower=$(echo "$model" | tr '[:upper:]' '[:lower:]')
case "$model_lower" in
    *opus*|*sonnet*|*claude*|*haiku*) actual_window=1000000 ;;
    *gemini*)                         actual_window=2000000 ;;
    *)                                actual_window="" ;;
esac
if [ -n "$actual_window" ] && [ -n "$window_size" ] && [ "$actual_window" -gt "$window_size" ]; then
    window_size=$actual_window
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

# Recalculate percentage if window size was overridden
if [ -n "$actual_window" ] && [ -n "$input_tokens" ] && [ "$input_tokens" != "0" ] && [ -n "$window_size" ]; then
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

# Line 1: agent | context gauge | model | effort
line1=''

if [ -n "$agent_display" ]; then
    line1="$agent_display"
fi

if [ -n "$ctx_gauge" ]; then
    [ -n "$line1" ] && line1="${line1} | "
    line1="${line1}${ctx_gauge}"
fi

[ -n "$line1" ] && line1="${line1} | "
line1=$(printf "%s\033[36m%s\033[0m" "$line1" "$model")

if [ -n "$effort_display" ]; then
    line1=$(printf "%s | %s" "$line1" "$effort_display")
fi

# Line 2: git branch | files | lines | duration | cost
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

# Message count (maintained by message-counter.sh UserPromptSubmit hook)
msg_count_file="$HOME/.claude/state/current-message-count"
if [ -f "$msg_count_file" ]; then
    msg_count=$(cat "$msg_count_file" 2>/dev/null)
    if [[ "$msg_count" =~ ^[0-9]+$ ]] && [ "$msg_count" -gt 0 ]; then
        [ -n "$line2" ] && line2="${line2} | "
        line2=$(printf "%s\033[38;5;245m💬%s\033[0m" "$line2" "$msg_count")
    fi
fi

# Session cost
session_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
if [ -n "$session_cost" ] && [ "$session_cost" != "0" ]; then
    usd_to_aud=1.42
    session_cost_aud=$(printf "%.2f" "$(echo "$session_cost * $usd_to_aud" | bc)")
    [ -n "$line2" ] && line2="${line2} | "
    line2=$(printf "%s\033[33mA\$%s\033[0m" "$line2" "$session_cost_aud")
fi

printf "%s\n%s\n" "$line1" "$line2"
