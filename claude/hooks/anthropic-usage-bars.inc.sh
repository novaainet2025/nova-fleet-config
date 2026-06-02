# Sourced by nco-statusline.sh — Anthropic OAuth usage bars (same data as /usage).
# API: GET https://api.anthropic.com/api/oauth/usage (undocumented; may change)
# - five_hour → 라벨 "1일" (실제는 5시간 롤링 블록)
# - seven_day → 라벨 "주별" (7일 롤링)

USAGE_CACHE_FILE="${HOME}/.claude/usage-statusline-cache.json"
USAGE_CACHE_MAX_AGE_SEC="${USAGE_CACHE_MAX_AGE_SEC:-180}"
USAGE_BAR_WIDTH="${USAGE_BAR_WIDTH:-8}"

_anthropic_read_creds_json() {
  local raw=""
  if [ -f "${HOME}/.claude/.credentials.json" ]; then
    raw=$(<"${HOME}/.claude/.credentials.json")
  fi
  if [ -z "$raw" ] && command -v security >/dev/null 2>&1; then
    raw=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
  fi
  printf '%s' "$raw"
}

_anthropic_usage_fetch() {
  local creds token resp
  creds=$(_anthropic_read_creds_json)
  token=$(printf '%s' "$creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  [ -n "$token" ] || return 1
  resp=$(curl -sS --max-time 4 \
    "https://api.anthropic.com/api/oauth/usage" \
    -H "Authorization: Bearer ${token}" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "Content-Type: application/json" 2>/dev/null) || return 1
  echo "$resp" | jq -e '.five_hour.utilization' >/dev/null 2>&1 || return 1
  printf '%s\n' "$resp" >"$USAGE_CACHE_FILE"
  return 0
}

_anthropic_usage_ensure_cache() {
  local now age
  if [ -f "$USAGE_CACHE_FILE" ]; then
    now=$(date +%s)
    age=$((now - $(stat -f %m "$USAGE_CACHE_FILE" 2>/dev/null || stat -c %Y "$USAGE_CACHE_FILE" 2>/dev/null || echo 0)))
    [ "$age" -lt "$USAGE_CACHE_MAX_AGE_SEC" ] && return 0
  fi
  _anthropic_usage_fetch || true
}

# Build █/░ bar; args: percent (0-100), width
_anthropic_usage_make_bar() {
  local pct=$1 width=$2 filled empty i
  pct=${pct%.*}
  [ "$pct" -lt 0 ] 2>/dev/null && pct=0
  [ "$pct" -gt 100 ] 2>/dev/null && pct=100
  filled=$(( (pct * width + 99) / 100 ))  # 올림: 1%라도 최소 1칸
  [ "$filled" -gt "$width" ] && filled=$width
  empty=$((width - filled))
  local bar=""
  [ "$filled" -gt 0 ] && printf -v bar '%*s' "$filled" '' && bar="${bar// /█}"
  [ "$empty" -gt 0 ] && printf -v bar '%s%*s' "$bar" "$empty" '' && bar="${bar// /░}"
  printf '%s' "$bar"
}

_anthropic_usage_color_for_pct() {
  local pct=$1
  pct=${pct%.*}
  [ "$pct" -lt 50 ] && printf '\033[32m' && return
  [ "$pct" -lt 80 ] && printf '\033[33m' && return
  printf '\033[91m'
}

# API resets_at(ISO8601) → 로컬 짧은 시각 (실패 시 빈 문자열)
_anthropic_resets_at_local() {
  local iso="$1"
  if [ -z "$iso" ] || [ "$iso" = "null" ]; then
    return 0
  fi
  python3 -c "
import sys
from datetime import datetime

def main():
    s = sys.argv[1] if len(sys.argv) > 1 else ''
    if not s:
        return
    try:
        if s.endswith('Z'):
            s = s[:-1] + '+00:00'
        dt = datetime.fromisoformat(s)
        if dt.tzinfo is not None:
            dt = dt.astimezone()
        print(dt.strftime('%m/%d %H:%M'))
    except Exception:
        pass

main()
" "$iso" 2>/dev/null
}

# 3번째 줄: 막대·퍼센트만
anthropic_usage_bars_render() {
  local u5 u7 c5 c7 b5 b7 s5 s7
  _anthropic_usage_ensure_cache
  [ -f "$USAGE_CACHE_FILE" ] || return 0
  u5=$(jq -r '.five_hour.utilization // empty' "$USAGE_CACHE_FILE" 2>/dev/null)
  u7=$(jq -r '.seven_day.utilization // empty' "$USAGE_CACHE_FILE" 2>/dev/null)
  [ -n "$u5" ] && [ "$u5" != "null" ] || return 0
  [ -n "$u7" ] && [ "$u7" != "null" ] || u7="0"

  c5=$(_anthropic_usage_color_for_pct "$u5")
  c7=$(_anthropic_usage_color_for_pct "$u7")
  b5=$(_anthropic_usage_make_bar "$u5" "$USAGE_BAR_WIDTH")
  b7=$(_anthropic_usage_make_bar "$u7" "$USAGE_BAR_WIDTH")
  s5=$(printf '%.0f' "$u5" 2>/dev/null || echo "0")
  s7=$(printf '%.0f' "$u7" 2>/dev/null || echo "0")

  printf '\033[90m1일\033[0m %s%s\033[0m %s%% \033[90m·\033[0m \033[90m주별\033[0m %s%s\033[0m %s%%' \
    "$c5" "$b5" "$s5" "$c7" "$b7" "$s7"
}

# 4번째 줄: ↻ 리셋 시각만
anthropic_usage_resets_render() {
  local u5 r5 r7 t5 t7
  _anthropic_usage_ensure_cache
  [ -f "$USAGE_CACHE_FILE" ] || return 0
  u5=$(jq -r '.five_hour.utilization // empty' "$USAGE_CACHE_FILE" 2>/dev/null)
  [ -n "$u5" ] && [ "$u5" != "null" ] || return 0

  r5=$(jq -r '.five_hour.resets_at // empty' "$USAGE_CACHE_FILE" 2>/dev/null)
  r7=$(jq -r '.seven_day.resets_at // empty' "$USAGE_CACHE_FILE" 2>/dev/null)
  t5=$(_anthropic_resets_at_local "$r5")
  t7=$(_anthropic_resets_at_local "$r7")

  if [ -n "$t5" ] && [ -n "$t7" ]; then
    printf '\033[90m↻\033[0m \033[90m1일\033[0m \033[90m%s\033[0m \033[90m·\033[0m \033[90m주별\033[0m \033[90m%s\033[0m' "$t5" "$t7"
  elif [ -n "$t5" ]; then
    printf '\033[90m↻\033[0m \033[90m1일\033[0m \033[90m%s\033[0m' "$t5"
  elif [ -n "$t7" ]; then
    printf '\033[90m↻\033[0m \033[90m주별\033[0m \033[90m%s\033[0m' "$t7"
  fi
}
