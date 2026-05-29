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
account_display=''
# Per-account state dir: respects CLAUDE_CONFIG_DIR so personal vs alt accounts
# read their own identity and cache pins.
claude_config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
case "$claude_config_dir" in
    "$HOME/.claude") account_label='personal' ;;
    "$HOME/.claude-alt") account_label='fho' ;;
    *) account_label=$(basename "$claude_config_dir") ;;
esac
identity_file="$claude_config_dir/state/current-session-identity.json"
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
# Peer ID from claude-peers MCP (matches what `list_peers` reports). Falls back
# to session_id[:8] when the peer broker isn't running or no peer is registered.
peer_id=''
peers_db="${CLAUDE_PEERS_DB:-$HOME/.claude-peers.db}"
if [ -f "$peers_db" ] && command -v sqlite3 >/dev/null 2>&1; then
    # Walk up the process tree to find the claude CLI ancestor.
    claude_pid=''
    walk_pid=$$
    for _ in 1 2 3 4 5 6; do
        [ -z "$walk_pid" ] || [ "$walk_pid" = "1" ] && break
        read wp wppid wcmd < <(ps -o pid=,ppid=,comm= -p "$walk_pid" 2>/dev/null)
        [ -z "$wp" ] && break
        case "$wcmd" in
            *claude) claude_pid="$wp"; break ;;
        esac
        walk_pid="$wppid"
    done
    if [ -n "$claude_pid" ]; then
        # Find children of the claude PID and look up their peer IDs.
        child_pids=$(ps -A -o pid=,ppid= | awk -v cp="$claude_pid" '$2==cp{print $1}')
        for cpid in $child_pids; do
            candidate=$(sqlite3 "$peers_db" "SELECT id FROM peers WHERE pid=$cpid LIMIT 1;" 2>/dev/null)
            if [ -n "$candidate" ]; then
                peer_id="$candidate"
                break
            fi
        done
    fi
fi
if [ -n "$peer_id" ]; then
    short_id="$peer_id"
elif [ -n "$session_id" ]; then
    short_id="${session_id:0:8}"
else
    short_id=''
fi
if [ -n "$short_id" ]; then
    agent_display=$(printf "${agent_ansi}%s %s\033[0m" "$agent_emoji" "$short_id")
    instance_display=$(printf "${agent_ansi}%s\033[0m" "$short_id")
fi
case "$account_label" in
    personal) account_ansi='\033[38;5;39m'  ;;  # blue
    fho)      account_ansi='\033[38;5;208m' ;;  # orange
    *)        account_ansi='\033[38;5;245m' ;;  # grey
esac
account_display=$(printf "${account_ansi}⎇ %s\033[0m" "$account_label")

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

# Derive canonical window size from model name; correct stale values from Claude Code.
# Sonnet/Haiku in 1M-context mode (e.g. claude-sonnet-4-6[1m]) get the 1M window.
model_lower=$(echo "$model" | tr '[:upper:]' '[:lower:]')
model_id=$(echo "$input" | jq -r '.model.id // empty' | tr '[:upper:]' '[:lower:]')
case "$model_lower" in
    *opus*)    canonical_window=1000000 ;;
    *sonnet*)  canonical_window=200000  ;;
    *haiku*)   canonical_window=200000  ;;
    *gemini*)  canonical_window=2000000 ;;
    *)         canonical_window=""      ;;
esac
case "$model_id$model_lower" in
    *'[1m]'*|*1m*) canonical_window=1000000 ;;
esac
# Use canonical size unconditionally when known -- ensures model switches are reflected immediately.
# But if Claude Code reports a larger window than canonical, trust the reported value.
if [ -n "$canonical_window" ]; then
    if [ -n "$window_size" ] && [ "$window_size" -gt "$canonical_window" ] 2>/dev/null; then
        :
    else
        window_size=$canonical_window
    fi
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
# Clamp to 100 -- protects against stale window_size after a mid-session model change
if [ -n "$used_pct" ] && [ "$used_pct" -gt 100 ] 2>/dev/null; then
    used_pct=100
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

    ctx_gauge=$(printf "${colour}${dial} ${used_pct}%%${health_hint}${reset}")
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
ahead_count='0'

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

    # Commits ahead of upstream (unpushed)
    upstream=$(git -C "$project_dir" rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null)
    if [ -n "$upstream" ]; then
        ahead_count=$(git -C "$project_dir" rev-list --count "${upstream}..HEAD" 2>/dev/null)
        [ -z "$ahead_count" ] && ahead_count='0'
    fi
fi

# Linear ticket link: extract first [A-Za-z]+-[0-9]+ from branch or worktree path,
# look up workspace from .claude/linear.json. Search order:
#   1. Walk up from project_dir
#   2. The git common dir (main worktree) if project_dir is a linked worktree
# Render as a plain https URL so Claude Code auto-linkifies it (cmd-click opens
# Linear desktop app on macOS, which handles linear.app URLs natively).
linear_display=''
if [ -n "$git_branch" ] || [ -n "$project_dir" ]; then
    ticket_source="$git_branch $(basename "$project_dir" 2>/dev/null)"
    linear_ticket=$(echo "$ticket_source" | grep -oE '[A-Za-z]+-[0-9]+' | head -n1 | tr '[:lower:]' '[:upper:]')

    if [ -n "$linear_ticket" ]; then
        # 1. Walk up from project_dir
        config_dir="$project_dir"
        linear_config=''
        while [ -n "$config_dir" ] && [ "$config_dir" != "/" ]; do
            if [ -f "$config_dir/.claude/linear.json" ]; then
                linear_config="$config_dir/.claude/linear.json"
                break
            fi
            config_dir=$(dirname "$config_dir")
        done

        # 2. Fallback: check the main worktree via git common dir
        if [ -z "$linear_config" ] && git -C "$project_dir" rev-parse --git-dir > /dev/null 2>&1; then
            common_dir=$(git -C "$project_dir" rev-parse --git-common-dir 2>/dev/null)
            if [ -n "$common_dir" ]; then
                # common_dir may be relative to project_dir
                case "$common_dir" in
                    /*) main_repo=$(dirname "$common_dir") ;;
                    *)  main_repo=$(cd "$project_dir/$common_dir/.." 2>/dev/null && pwd) ;;
                esac
                if [ -n "$main_repo" ] && [ -f "$main_repo/.claude/linear.json" ]; then
                    linear_config="$main_repo/.claude/linear.json"
                fi
            fi
        fi

        if [ -n "$linear_config" ]; then
            linear_workspace=$(jq -r '.workspace // empty' "$linear_config" 2>/dev/null)
            if [ -n "$linear_workspace" ]; then
                linear_url="https://linear.app/${linear_workspace}/issue/${linear_ticket}"
                # OSC 8 hyperlink: requires terminal hyperlink support.
                # If link is not clickable, run claude with FORCE_HYPERLINK=1.
                # Format matches Claude Code's own internal links.
                esc=$(printf '\033')
                st=$(printf '\033\\')
                linear_display=$(printf "\033[38;5;141m🎫%s]8;;%s%s%s%s]8;;%s\033[0m" "$esc" "$linear_url" "$st" "$linear_ticket" "$esc" "$st")
            fi
        fi
    fi
fi

# Peak-hour dispatch-only guard: 21:00-22:00 local is reserved focus time and
# should be spent batching tasks to the queue, not grinding manual turns. Show a
# quiet reminder during that window only.
dispatch_guard=''
if command -v python3 >/dev/null 2>&1; then
    dispatch_guard=$(python3 -c "
from datetime import datetime
h = datetime.now().astimezone().hour
if h == 21:
    print('\x1b[38;5;141m🌙 21:00 dispatch-only\x1b[0m', end='')
" 2>/dev/null)
fi

# Line 1: agent | context gauge | model | effort | week pace label
line1=''

if [ -n "$agent_display" ]; then
    line1="${agent_display}"
fi

if [ -n "$account_display" ]; then
    [ -n "$line1" ] && line1="${line1} | "
    line1="${line1}${account_display}"
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

# Line 2: linear ticket | unpushed commits | files +/- | duration | cost | message count | last response | branch
line2=''

if [ -n "$linear_display" ]; then
    line2="${linear_display}"
fi

if [ -n "$ahead_count" ] && [ "$ahead_count" -gt 0 ]; then
    if [ "$ahead_count" -le 2 ]; then
        ahead_colour='\033[38;5;112m'   # light green
        ahead_hint=''
    elif [ "$ahead_count" -le 4 ]; then
        ahead_colour='\033[38;5;220m'   # yellow
        ahead_hint=' ⚠ push soon'
    elif [ "$ahead_count" -le 6 ]; then
        ahead_colour='\033[38;5;208m'   # orange
        ahead_hint=' ⚠ push soon'
    else
        ahead_colour='\033[38;5;196m'   # red
        ahead_hint=' 🛑 push now'
    fi
    [ -n "$line2" ] && line2="${line2} | "
    line2=$(printf "%s${ahead_colour}↑%s unpushed${ahead_hint}\033[0m" "$line2" "$ahead_count")
fi

if [ -n "$files_changed" ]; then
    [ -n "$line2" ] && line2="${line2} | "
    if [ "$files_changed" -eq 0 ]; then
        line2=$(printf "%s\033[38;5;34m✓ clean\033[0m" "$line2")
    else
        # Heat gradient + commit reminder, similar to context gauge
        if [ "$files_changed" -le 2 ]; then
            file_colour='\033[38;5;112m'   # light green - small change
            dirty_hint=''
        elif [ "$files_changed" -le 4 ]; then
            file_colour='\033[38;5;220m'   # yellow - getting big
            dirty_hint=' ⚠ commit soon'
        elif [ "$files_changed" -le 6 ]; then
            file_colour='\033[38;5;208m'   # orange - commit soon
            dirty_hint=' ⚠ commit soon'
        elif [ "$files_changed" -le 9 ]; then
            file_colour='\033[38;5;196m'   # red - commit now
            dirty_hint=' 🛑 commit now'
        else
            file_colour='\033[38;5;160m'   # dark red - critical
            dirty_hint=' 🛑 commit now'
        fi
        line2=$(printf "%s${file_colour}%s files\033[0m \033[36m%s\033[0m${file_colour}${dirty_hint}\033[0m" "$line2" "$files_changed" "$lines_changed")
    fi
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
    # Staged thread-health hints on a single counter. Long threads cost a fixed
    # per-message context tax and lose their own plot once they run too long, so
    # the nudge escalates with turn count:
    #   ~150  yellow  - getting long, plan a handoff point
    #   ~300  orange  - handoff to a file and reopen fresh (the plot-loss line)
    #   ~2000 red     - hard stop: compact or start a new chat
    if [ "$msg_count" -lt 150 ]; then
        msg_colour='\033[38;5;245m'   # grey - plenty of headroom
        msg_hint=''
    elif [ "$msg_count" -lt 300 ]; then
        msg_colour='\033[38;5;220m'   # yellow - getting long
        msg_hint=' ⚠ plan handoff'
    elif [ "$msg_count" -lt 2000 ]; then
        msg_colour='\033[38;5;208m'   # orange - handoff and reopen fresh
        msg_hint=' 👝 handoff + fresh chat'
    else
        msg_colour='\033[38;5;196m'   # red - hard stop
        msg_hint=' 🛑 compact or new chat'
    fi
    [ -n "$line2" ] && line2="${line2} | "
    line2=$(printf "%s${msg_colour}💬%s${msg_hint}\033[0m" "$line2" "$msg_count")
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

# 7-day Anthropic Max quota pace (sourced from the Raycast "Claude Usage" extension cache).
# Resolves the cache file path once and stores it in ~/.claude/state/seven-day-usage-cache-path
# so we don't scan the cache directory on every render.
week_display=''
week_path_cache="$claude_config_dir/state/seven-day-usage-cache-path"
week_data_file=''
if [ -f "$week_path_cache" ]; then
    candidate=$(cat "$week_path_cache" 2>/dev/null)
    if [ -n "$candidate" ] && [ -f "$candidate" ] && head -c 30 "$candidate" 2>/dev/null | grep -q 'five_hour'; then
        week_data_file="$candidate"
    fi
fi
if [ -z "$week_data_file" ]; then
    raycast_root="$HOME/Library/Application Support/com.raycast.macos/extensions"
    if [ -d "$raycast_root" ]; then
        for f in "$raycast_root"/*/com.raycast.api.cache/*; do
            [ -f "$f" ] || continue
            if head -c 30 "$f" 2>/dev/null | grep -q 'five_hour'; then
                week_data_file="$f"
                mkdir -p "$(dirname "$week_path_cache")"
                printf '%s' "$f" > "$week_path_cache"
                break
            fi
        done
    fi
fi

week_render=''
if [ -n "$week_data_file" ] && [ -f "$week_data_file" ]; then
    week_util=$(jq -r '.seven_day.utilization // empty' "$week_data_file" 2>/dev/null)
    week_reset=$(jq -r '.seven_day.resets_at // empty' "$week_data_file" 2>/dev/null)
    if [ -n "$week_util" ] && [ -n "$week_reset" ] && command -v python3 >/dev/null 2>&1; then
        week_stale='0'
        if find "$week_data_file" -mmin +30 2>/dev/null | grep -q .; then
            week_stale='1'
        fi

        week_render=$(WEEK_UTIL="$week_util" WEEK_RESET="$week_reset" WEEK_STALE="$week_stale" python3 - <<'PYEOF'
import os
from datetime import datetime, timezone

util = float(os.environ['WEEK_UTIL'])
reset = datetime.fromisoformat(os.environ['WEEK_RESET'].replace('Z', '+00:00'))
stale = os.environ.get('WEEK_STALE') == '1'

now = datetime.now(timezone.utc)
window_h = 7 * 24
hours_left = max(0.0, (reset - now).total_seconds() / 3600.0)
progress = max(0.0, min(100.0, (window_h - hours_left) / window_h * 100.0))
est = (util / progress * 100.0) if progress > 0 else util
diff = util - progress  # negative = under pace, positive = over pace

if est >= 100 and progress > 5:
    fg = '38;5;196'
    label = f'\U0001f6d1 {int(round(diff))}% over pace'
elif diff < -1:
    fg = '38;5;34'
    label = f'+{int(round(-diff))}% spare'
elif diff > 1:
    fg = '38;5;208'
    label = f'{int(round(diff))}% over'
else:
    fg = '38;5;220'
    label = 'on track'

if stale:
    fg = '38;5;245'

print(f'\x1b[{fg}m{label}\x1b[0m', end='')
PYEOF
)
    fi
fi

if [ -n "$week_render" ]; then
    line1="${line1} | ${week_render}"
fi

if [ -n "$dispatch_guard" ]; then
    line1="${line1} | ${dispatch_guard}"
fi

if [ -n "$git_branch" ]; then
    [ -n "$line2" ] && line2="${line2} | "
    line2=$(printf "%s\033[38;5;245m%s\033[0m" "$line2" "$git_branch")
fi

printf "%s\n%s\n" "$line1" "$line2"
