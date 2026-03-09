#!/bin/bash
# Status line script for Claude Code
# Displays: model | output_style | project_dir | git_branch | git_status | files | lines

input=$(cat)
model=$(echo "$input" | jq -r '.model.display_name')
output_style=$(echo "$input" | jq -r '.output_style.name')
project_dir=$(echo "$input" | jq -r '.workspace.project_dir')

# Context window gauge
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // empty')
window_size=$(echo "$input" | jq -r '.context_window.context_window_size // empty')

ctx_gauge=''
if [ -n "$used_pct" ] && [ -n "$input_tokens" ] && [ -n "$window_size" ]; then
    # Dial icon based on quartile
    if [ "$used_pct" -lt 25 ]; then
        dial='◔'
    elif [ "$used_pct" -lt 50 ]; then
        dial='◑'
    elif [ "$used_pct" -lt 75 ]; then
        dial='◶'
    else
        dial='●'
    fi

    # Colour based on usage (ANSI escape codes)
    if [ "$used_pct" -lt 50 ]; then
        colour='\033[32m'  # green
    elif [ "$used_pct" -lt 75 ]; then
        colour='\033[33m'  # yellow
    elif [ "$used_pct" -lt 90 ]; then
        colour='\033[38;5;208m'  # orange
    else
        colour='\033[31m'  # red
    fi
    reset='\033[0m'

    # Mini bar graph (8 blocks for visual resolution)
    blocks='▁▂▃▄▅▆▇█'
    # Calculate how many of 8 segments are filled
    filled=$(( (used_pct * 8 + 50) / 100 ))
    [ "$filled" -lt 1 ] && filled=1
    [ "$filled" -gt 8 ] && filled=8
    bar=''
    i=1
    while [ "$i" -le 8 ]; do
        if [ "$i" -le "$filled" ]; then
            # Extract the block character at position $filled (use the highest filled level)
            char=$(echo "$blocks" | cut -c"$i")
            bar="${bar}${char}"
        else
            bar="${bar}▁"
        fi
        i=$((i + 1))
    done

    # Compact token display (e.g. 98k/200k)
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

    ctx_gauge=$(printf "${colour}${dial} ${used_pct}%% ${bar} ${used_display}/${total_display}${reset}")
fi

# Session cost
session_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
cost_display=''
if [ -n "$session_cost" ]; then
    # Convert USD to AUD (update rate periodically)
    usd_to_aud=1.42
    session_cost_aud=$(printf "%.2f" "$(echo "$session_cost * $usd_to_aud" | bc)")
    cost_display=$(printf "\033[33mA\$%s\033[0m" "$session_cost_aud")
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

# Build status line with colors
status_parts=$(printf "\033[36m%s\033[0m | \033[35m%s\033[0m | \033[32m%s\033[0m" "$model" "$output_style" "$project_dir")

if [ -n "$git_branch" ]; then
    status_parts=$(printf "%s | \033[33m%s\033[0m" "$status_parts" "$git_branch")

    if [ "$git_status" = 'clean' ]; then
        status_parts=$(printf "%s | \033[32m%s\033[0m" "$status_parts" "$git_status")
    else
        status_parts=$(printf "%s | \033[31m%s\033[0m" "$status_parts" "$git_status")
    fi

    status_parts=$(printf "%s | \033[34m%s files\033[0m" "$status_parts" "$files_changed")
    status_parts=$(printf "%s | \033[36m%s\033[0m" "$status_parts" "$lines_changed")
fi

# Assemble final status line: context gauge | cost | duration | main parts
output="$status_parts"

# Prepend duration, cost, and context gauge (right to left so order is gauge | cost | duration | ...)
if [ -n "$duration_display" ]; then
    output="${duration_display} | ${output}"
fi
if [ -n "$cost_display" ]; then
    output="${cost_display} | ${output}"
fi
if [ -n "$ctx_gauge" ]; then
    output="${ctx_gauge} | ${output}"
fi

echo "$output"
