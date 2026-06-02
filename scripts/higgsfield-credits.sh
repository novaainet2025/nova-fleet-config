#!/usr/bin/env bash
# higgsfield-credits.sh — Higgsfield 잔여 크레딧 + 당일 사용량 (캐시 기반)
#
# 상태바는 매 렌더마다 호출되므로 `higgsfield account status`(네트워크 ~1-2s)를
# 인라인으로 부르면 안 된다. 따라서 캐시 파일을 두고, 만료 시에만 백그라운드로
# 갱신한다(렌더는 절대 블로킹되지 않음).
#
#   (인자 없음)  render : 캐시 파싱 출력 "credits|plan|today_spend" + 만료 시 백그라운드 갱신 트리거
#   --refresh    fetch  : higgsfield account 호출 → 캐시 atomic 기록 (lock으로 중복 방지)
#
# 캐시: ~/.claude/cache/hf-credits.json  { credits, plan, today_spend, updated_at }
# today_spend: 로컬(KST) 자정 이후 spend 트랜잭션 합(절대값). 트랜잭션 타임스탬프는
#              UTC이므로 .astimezone()으로 로컬 변환 후 날짜 비교.

CACHE_DIR="$HOME/.claude/cache"
CACHE="$CACHE_DIR/hf-credits.json"
LOCK="$CACHE_DIR/hf-credits.refresh.lock"   # mkdir 기반 atomic lock
TTL=300                                       # 캐시 신선도(초). 5분.
LOCK_STALE=120                                # 이 시간(초) 넘은 lock은 죽은 것으로 간주

_now() { date +%s; }
# 이식성: GNU(stat -c) / BSD·macOS(stat -f) 둘 다 지원
_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
# 이식성: macOS는 timeout/gtimeout이 기본 부재 → 있으면 사용, 없으면 timeout 없이 실행
# (refresh는 백그라운드 detach라 timeout 없어도 statusline 렌더는 비차단)
_to() { if command -v timeout >/dev/null 2>&1; then timeout "$@"; elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$@"; else shift; "$@"; fi; }

_trigger_refresh() {
  # lock이 없을 때만 detached 로 갱신 — 렌더 storm 방지.
  # 렌더 비차단의 핵심은 *FD1(statusline 파이프) 분리*(>/dev/null 2>&1 </dev/null).
  # setsid는 controlling-terminal까지 떼는 추가 강화지만 macOS엔 없을 수 있음 → 폴백.
  [ -d "$LOCK" ] && return 0
  if command -v setsid >/dev/null 2>&1; then
    setsid bash "$0" --refresh >/dev/null 2>&1 < /dev/null &
  else
    ( bash "$0" --refresh >/dev/null 2>&1 < /dev/null & ) >/dev/null 2>&1
  fi
}

refresh() {
  mkdir -p "$CACHE_DIR"
  # 중복 refresh 방지: mkdir은 atomic. 죽은(오래된) lock은 회수.
  if ! mkdir "$LOCK" 2>/dev/null; then
    local age=$(( $(_now) - $(_mtime "$LOCK") ))
    if [ "$age" -gt "$LOCK_STALE" ]; then
      rmdir "$LOCK" 2>/dev/null
      mkdir "$LOCK" 2>/dev/null || exit 0
    else
      exit 0   # 다른 refresh 진행 중
    fi
  fi
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT

  command -v higgsfield >/dev/null 2>&1 || exit 0

  local acct tx
  acct=$(_to 20 higgsfield account status --json 2>/dev/null)
  [ -z "$acct" ] && exit 0
  tx=$(_to 20 higgsfield account transactions --size 100 --json 2>/dev/null)

  printf '%s\n---TX---\n%s' "$acct" "$tx" | python3 -c '
import sys, json
from datetime import datetime, timezone
raw = sys.stdin.read()
acct_s, _, tx_s = raw.partition("\n---TX---\n")
try:
    acct = json.loads(acct_s)
except Exception:
    sys.exit(0)
credits = acct.get("credits")
plan = acct.get("subscription_plan_type", "") or ""
today_spend = 0.0
try:
    txs = json.loads(tx_s) if tx_s.strip() else []
    today = datetime.now().astimezone().date()
    for t in txs:
        if t.get("action") != "spend":
            continue
        ts = t.get("created_at", "")
        try:
            dt = datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone()
        except Exception:
            continue
        if dt.date() == today:
            today_spend += abs(t.get("credits", 0) or 0)
except Exception:
    pass
out = {
    "credits": credits,
    "plan": plan,
    "today_spend": today_spend,
    "updated_at": int(datetime.now(timezone.utc).timestamp()),
}
print(json.dumps(out))
' > "$CACHE.tmp" 2>/dev/null

  if [ -s "$CACHE.tmp" ]; then
    mv -f "$CACHE.tmp" "$CACHE"
  else
    rm -f "$CACHE.tmp"
  fi
}

case "$1" in
  --refresh)
    refresh
    ;;
  *)
    # render: 캐시가 있으면 파싱해서 출력
    if [ -f "$CACHE" ]; then
      python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    c = d.get("credits")
    p = d.get("plan", "") or ""
    s = d.get("today_spend", 0) or 0
    cs = ("%g" % c) if isinstance(c, (int, float)) else ""
    print("%s|%s|%g" % (cs, p, s))
except Exception:
    print("")
' "$CACHE" 2>/dev/null
      # 만료 시 백그라운드 갱신
      age=$(( $(_now) - $(_mtime "$CACHE") ))
      [ "$age" -gt "$TTL" ] && _trigger_refresh
    else
      # 캐시 없음 → 첫 갱신 트리거, 이번 렌더는 빈 출력
      _trigger_refresh
    fi
    ;;
esac
