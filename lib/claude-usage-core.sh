#!/usr/bin/env bash
# Shared Claude usage core: resolve a config dir's identity + weekly headroom and
# emit a single JSON object. Reuses the Raycast cache-resolution and pace maths
# from claude-usage.sh, but never crashes on a missing cache or missing identity.
#
# Usage: bash claude-usage-core.sh --config-dir DIR --json
#   DIR defaults to ${CLAUDE_CONFIG_DIR:-$HOME/.claude}
#
# Output JSON fields:
#   account_label      personal | fho
#   account_email      string | null
#   account_uuid_short first 8 chars of accountUuid | null
#   org_name           string | null
#   subscription       string | null
#   rate_limit_tier    string | null
#   source             raycast-cache | none
#   fresh              bool (false if cache mtime older than 30 min)
#   stale_minutes      int
#   five_hour          { used_pct, resets_at } | null
#   seven_day          { used_pct, resets_at, spare_pct, pace } | null
#   seven_day_opus     { used_pct, resets_at } | null
#   extra_usage        { enabled, used_credits, monthly_limit } | null

set -euo pipefail

config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
emit_json='0'

while [ "$#" -gt 0 ]; do
    case "$1" in
        --config-dir)
            shift
            config_dir="${1:-$config_dir}"
            ;;
        --json)
            emit_json='1'
            ;;
        -h|--help)
            sed -n '2,24p' "$0"
            exit 0
            ;;
        *)
            printf "Unknown argument: %s\n" "$1" >&2
            exit 2
            ;;
    esac
    shift
done

# --json is the only supported output for now; keep the flag explicit so callers
# opt in and we can add other formats later without surprising them.
if [ "$emit_json" != "1" ]; then
    printf "claude-usage-core.sh requires --json\n" >&2
    exit 2
fi

have_jq='0'
if command -v jq >/dev/null 2>&1; then
    have_jq='1'
fi

# Normalise the config dir (strip a trailing slash) so identity lookups line up.
dir="${config_dir%/}"

# account_label: fho when the dir is ~/.claude-alt, else personal.
account_label='personal'
case "$dir" in
    "$HOME/.claude-alt"|"$HOME/.claude-alt/") account_label='fho' ;;
esac

# ---------------------------------------------------------------------------
# Identity: DIR/.claude.json first, then sibling ${DIR}.json (e.g. ~/.claude-alt.json),
# then DIR/.credentials.json for subscription/tier only.
# ---------------------------------------------------------------------------
account_email=''
account_uuid=''
org_name=''
subscription=''
rate_limit_tier=''

identity_file=''
if [ -f "$dir/.claude.json" ]; then
    identity_file="$dir/.claude.json"
elif [ -f "${dir}.json" ]; then
    identity_file="${dir}.json"
fi

if [ -n "$identity_file" ] && [ "$have_jq" = "1" ]; then
    account_email=$(jq -r '.oauthAccount.emailAddress // empty' "$identity_file" 2>/dev/null || true)
    account_uuid=$(jq -r '.oauthAccount.accountUuid // empty' "$identity_file" 2>/dev/null || true)
    org_name=$(jq -r '.oauthAccount.organizationName // empty' "$identity_file" 2>/dev/null || true)
fi

cred_file="$dir/.credentials.json"
if [ -f "$cred_file" ] && [ "$have_jq" = "1" ]; then
    subscription=$(jq -r '.claudeAiOauth.subscriptionType // empty' "$cred_file" 2>/dev/null || true)
    rate_limit_tier=$(jq -r '.claudeAiOauth.rateLimitTier // empty' "$cred_file" 2>/dev/null || true)
fi

# Fall back to organisation rate-limit tier from the identity file when the
# credentials file is absent (FHO-style dirs may have one but not the other).
if [ -z "$rate_limit_tier" ] && [ -n "$identity_file" ] && [ "$have_jq" = "1" ]; then
    rate_limit_tier=$(jq -r '.oauthAccount.organizationRateLimitTier // empty' "$identity_file" 2>/dev/null || true)
fi

account_uuid_short=''
if [ -n "$account_uuid" ]; then
    account_uuid_short="${account_uuid:0:8}"
fi

# ---------------------------------------------------------------------------
# Cache resolution: pointer file first, then scan the Raycast extensions dir.
# Lifted from claude-usage.sh; does not write back to the pointer (read-only core).
# ---------------------------------------------------------------------------
cache_file=''
path_cache="$dir/state/seven-day-usage-cache-path"
if [ -f "$path_cache" ]; then
    candidate=$(cat "$path_cache" 2>/dev/null || true)
    if [ -n "$candidate" ] && [ -f "$candidate" ] && head -c 80 "$candidate" 2>/dev/null | grep -q 'seven_day'; then
        cache_file="$candidate"
    fi
fi

# The Raycast extension cache is global (not per-account). Only scan for it as a
# fallback when DIR is the default personal dir; for any other config dir (e.g.
# ~/.claude-alt / FHO) a missing pointer means we genuinely have no local data,
# and we must not attribute the personal cache to it.
if [ -z "$cache_file" ] && [ "$account_label" = "personal" ]; then
    raycast_root="$HOME/Library/Application Support/com.raycast.macos/extensions"
    if [ -d "$raycast_root" ]; then
        for candidate in "$raycast_root"/*/com.raycast.api.cache/*; do
            [ -f "$candidate" ] || continue
            if head -c 160 "$candidate" 2>/dev/null | grep -q 'seven_day'; then
                cache_file="$candidate"
                break
            fi
        done
    fi
fi

# ---------------------------------------------------------------------------
# Build the usage payload. python3 does the maths + JSON assembly so we get the
# exact pace logic from claude-usage.sh and robust ISO date handling. If python3
# or jq is missing, or there is no cache, we fall back to a null/none payload.
# ---------------------------------------------------------------------------
usage_payload=''
source='none'
fresh='false'
stale_minutes='0'

if [ -n "$cache_file" ] && [ -f "$cache_file" ] && [ "$have_jq" = "1" ] && command -v python3 >/dev/null 2>&1; then
    if cache_minutes=$(python3 - "$cache_file" <<'PYEOF'
import os, sys, time
path = sys.argv[1]
try:
    mtime = os.path.getmtime(path)
    print(int((time.time() - mtime) / 60))
except OSError:
    print("")
PYEOF
    ) && [ -n "$cache_minutes" ]; then
        source='raycast-cache'
        stale_minutes="$cache_minutes"
        if [ "$cache_minutes" -lt 30 ]; then
            fresh='true'
        fi
    fi
fi

if [ "$source" = "raycast-cache" ]; then
    usage_payload=$(CACHE_FILE="$cache_file" python3 - <<'PYEOF'
import json, os
from datetime import datetime, timezone

with open(os.environ["CACHE_FILE"]) as fh:
    data = json.load(fh)


def parse_iso(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def simple_block(block):
    if not isinstance(block, dict):
        return None
    util = block.get("utilization")
    if util is None:
        return None
    return {"used_pct": round(float(util)), "resets_at": block.get("resets_at")}


def seven_day_block(block):
    if not isinstance(block, dict):
        return None
    util = block.get("utilization")
    if util is None:
        return None
    used = round(float(util))
    resets_at = block.get("resets_at")
    spare_pct = round(100.0 - float(util))

    # Pace: elapsed fraction of the 7-day window ending at resets_at.
    pace = "on track"
    reset_dt = parse_iso(resets_at)
    if reset_dt is not None:
        window_h = 7 * 24
        now = datetime.now(timezone.utc)
        hours_left = max(0.0, (reset_dt - now).total_seconds() / 3600.0)
        progress = max(0.0, min(100.0, (window_h - hours_left) / window_h * 100.0))
        diff = progress - float(util)  # positive => under pace (spare)
        if diff > 1:
            pace = "+%d%% spare" % round(diff)
        elif diff < -1:
            pace = "-%d%% over pace" % round(-diff)
        else:
            pace = "on track"

    return {
        "used_pct": used,
        "resets_at": resets_at,
        "spare_pct": spare_pct,
        "pace": pace,
    }


extra = data.get("extra_usage")
if isinstance(extra, dict):
    extra_out = {
        "enabled": bool(extra.get("is_enabled")),
        "used_credits": extra.get("used_credits"),
        "monthly_limit": extra.get("monthly_limit"),
    }
else:
    extra_out = None

payload = {
    "five_hour": simple_block(data.get("five_hour")),
    "seven_day": seven_day_block(data.get("seven_day")),
    "seven_day_opus": simple_block(data.get("seven_day_opus")),
    "extra_usage": extra_out,
}
print(json.dumps(payload))
PYEOF
    ) || usage_payload=''
fi

# If the usage maths failed for any reason, downgrade to a clean none payload.
if [ -z "$usage_payload" ]; then
    source='none'
    fresh='false'
    stale_minutes='0'
    usage_payload='{"five_hour":null,"seven_day":null,"seven_day_opus":null,"extra_usage":null}'
fi

# ---------------------------------------------------------------------------
# Assemble the final object. Prefer jq for safe string encoding; fall back to a
# careful printf if jq is somehow unavailable.
# ---------------------------------------------------------------------------
if [ "$have_jq" = "1" ]; then
    jq -n \
        --arg account_label "$account_label" \
        --arg account_email "$account_email" \
        --arg account_uuid_short "$account_uuid_short" \
        --arg org_name "$org_name" \
        --arg subscription "$subscription" \
        --arg rate_limit_tier "$rate_limit_tier" \
        --arg source "$source" \
        --argjson fresh "$fresh" \
        --argjson stale_minutes "$stale_minutes" \
        --argjson usage "$usage_payload" \
        '{
            account_label: $account_label,
            account_email: (if $account_email == "" then null else $account_email end),
            account_uuid_short: (if $account_uuid_short == "" then null else $account_uuid_short end),
            org_name: (if $org_name == "" then null else $org_name end),
            subscription: (if $subscription == "" then null else $subscription end),
            rate_limit_tier: (if $rate_limit_tier == "" then null else $rate_limit_tier end),
            source: $source,
            fresh: $fresh,
            stale_minutes: $stale_minutes,
            five_hour: $usage.five_hour,
            seven_day: $usage.seven_day,
            seven_day_opus: $usage.seven_day_opus,
            extra_usage: $usage.extra_usage
        }'
else
    # jq-free fallback: assemble manually. Identity strings are simple (emails,
    # uuids, tier slugs) so no escaping is required here.
    printf '{'
    printf '"account_label":"%s",' "$account_label"
    printf '"account_email":%s,' "$( [ -n "$account_email" ] && printf '"%s"' "$account_email" || printf 'null' )"
    printf '"account_uuid_short":%s,' "$( [ -n "$account_uuid_short" ] && printf '"%s"' "$account_uuid_short" || printf 'null' )"
    printf '"org_name":%s,' "$( [ -n "$org_name" ] && printf '"%s"' "$org_name" || printf 'null' )"
    printf '"subscription":%s,' "$( [ -n "$subscription" ] && printf '"%s"' "$subscription" || printf 'null' )"
    printf '"rate_limit_tier":%s,' "$( [ -n "$rate_limit_tier" ] && printf '"%s"' "$rate_limit_tier" || printf 'null' )"
    printf '"source":"%s",' "$source"
    printf '"fresh":%s,' "$fresh"
    printf '"stale_minutes":%s,' "$stale_minutes"
    # usage_payload is itself valid JSON for the usage sub-fields; splice it in.
    five=$(printf '%s' "$usage_payload" | sed 's/^{//; s/}$//')
    printf '%s' "$five"
    printf '}\n'
fi
