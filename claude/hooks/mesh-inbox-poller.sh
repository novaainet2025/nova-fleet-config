#!/bin/bash
# mesh-inbox-poller.sh — 내 세션 앞으로 온 새 mesh DM을 즉시 stdout에 emit
# 사용:
#   bash mesh-inbox-poller.sh <my_session_id> <my_agent_name> [interval_sec]
# 출력 (stdout):
#   [NEW <type>] <from_agent>(<from_session>) → <content[:160]>
# 의도:
#   - Monitor 도구로 호출 시 각 라인이 system notification
#   - 백그라운드 데몬으로 호출 시 stdout을 파일로 append
# 충돌 회피:
#   - autoresponder(mesh-autoresponder.sh)와 동일 메시지 중복 처리하지 않도록
#     id-dedupe 만 수행(autoresponder가 답장은 알아서). 이 스크립트는 "알림"만.

set -u

PID="${1:?usage: mesh-inbox-poller.sh <session_id> <agent_name> [interval]}"
AGENT="${2:?usage: mesh-inbox-poller.sh <session_id> <agent_name> [interval]}"
INTERVAL="${3:-5}"

# env 격리 (결함 #3 fix, 2026-05-26):
# 부모 Claude의 NCO_SESSION_ID/NCO_NAME envvar가 자식 poller에 상속되어
# 4개 poller 전부 동일한 claude-1 envvar를 들고 다니던 문제 해결.
# 인자값으로 받은 PID/AGENT를 정답으로 강제 export.
export NCO_SESSION_ID="$PID"
export NCO_NAME="$AGENT"

API="${NCO_API:-http://localhost:6200}"
STATE_DIR="/tmp/nco-inbox-${PID}"
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/last_id"
PID_FILE="$STATE_DIR/poller.pid"

# Single-instance guard: if another poller for this session is already running, exit
if [ -f "$PID_FILE" ]; then
  _old=$(cat "$PID_FILE" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$_old" ] && ps -p "$_old" >/dev/null 2>&1; then
    echo "[mesh-watch] already running (pid=$_old) — exiting"
    exit 0
  fi
fi
echo $$ > "$PID_FILE"

# Monitor mode (INTER_MODE=monitor): create lock so mesh-auto-responder yields
# to Claude. inter-session 동치 동작. Lock 파일 1개당 1세션 = 단순한 게이트.
LOCK_FILE=""
if [ "${INTER_MODE:-}" = "monitor" ]; then
  LOCK_FILE="$STATE_DIR/monitor.lock"
  echo "$$" > "$LOCK_FILE"
  echo "[mesh-receiver] connected as ${AGENT} (session ${PID}) — listening for mesh DMs"
fi

trap 'rm -f "$PID_FILE"; [ -n "$LOCK_FILE" ] && rm -f "$LOCK_FILE"' EXIT

# Prime: arm watermark with current newest id so we only emit truly NEW
PRIME=$(curl -s --max-time 4 "${API}/api/mesh/messages?limit=1" 2>/dev/null \
  | python3 -c "import json,sys
try:
  d=json.load(sys.stdin); m=d.get('messages',[])
  print(m[0]['id'] if m else '')
except: print('')" 2>/dev/null)
echo "${PRIME}" > "$STATE_FILE"
# P1-E (2026-05-26): record spawn_ts so consumers can know when this poller armed,
# avoiding stale-watermark hazard from PRIME=newest_id alone.
date +%s > "$STATE_DIR/spawn_ts" 2>/dev/null || true
echo "[mesh-watch armed] session=$PID agent=$AGENT interval=${INTERVAL}s last_id=${PRIME:-none}"

while true; do
  # P1-A (2026-05-26): touch monitor.lock each poll cycle so auto-responder can
  # detect liveness via mtime (combined with kill -0 PID check on consumer side).
  [ -n "$LOCK_FILE" ] && touch "$LOCK_FILE" 2>/dev/null || true
  LAST=$(cat "$STATE_FILE" 2>/dev/null || echo "")
  RESP=$(curl -s --max-time 4 "${API}/api/mesh/messages?limit=30" 2>/dev/null || echo "")
  if [ -z "$RESP" ]; then
    sleep "$INTERVAL"
    continue
  fi
  # client-side filter + dedupe + emit
  RESP="$RESP" LAST="$LAST" PID="$PID" AGENT="$AGENT" STATE_FILE="$STATE_FILE" python3 <<'PYEOF'
import json, sys, os
last     = os.environ.get("LAST","")
me_pid   = os.environ.get("PID","")
me_agent = os.environ.get("AGENT","")
state_f  = os.environ.get("STATE_FILE")
resp     = os.environ.get("RESP","")

try:
    d = json.loads(resp)
except Exception:
    sys.exit(0)

msgs = d.get("messages", [])
if not msgs:
    sys.exit(0)

# messages come newest-first; walk until we hit watermark
fresh = []
for m in msgs:
    if m.get("id") == last:
        break
    fresh.append(m)

# bump watermark to newest seen (even if filtered out — don't re-scan)
try:
    with open(state_f, "w") as f:
        f.write(msgs[0]["id"])
except Exception:
    pass

# filter: addressed to me (by session id OR agent name).
# broadcast ("*") is skipped — autoresponder handles those separately and they
# would otherwise flood every session's next prompt with noise.
addressed = []
for m in reversed(fresh):  # emit oldest→newest in this batch
    to = str(m.get("to_session", ""))
    if to == me_pid or to == me_agent:
        addressed.append(m)
    # R3 (2026-05-27): broadcast(*) + type=task 또는 scope=direct → wake-up.
    # 일반 broadcast는 noise이지만 명시적 task/direct 위임은 처리 필요
    # (claude-3 R3 분석: type_task_supported_in_broadcast=FALSE 원인).
    elif to == "*" and (m.get("type") == "task" or m.get("scope") == "direct"):
        addressed.append(m)
    # else: to == "*" 일반 또는 unknown → skip silently

# Output format: [NEW <type>:<scope>] <fa>(<fs>) -> <content (newline-escaped, ≤800)>
# scope is appended after ':' so the consumer (user-prompt-nco-context.sh) can
# decide whether to expand the body fully (type=task or scope=direct) or just
# show a 160-char preview (info/broadcast). Legacy scope='' still parses.
for m in addressed:
    fa = m.get("from_agent","?")
    fs = m.get("from_session","?")
    t  = (m.get("type","info") or "info")[:8]
    sc = (m.get("scope") or "")[:8]
    mid = (m.get("id") or "")[:16] or "noid"
    c_raw = (m.get("content","") or "")
    c_esc = c_raw.replace("\r"," ").replace("\n","\\n")[:800]
    print(f"[NEW {t}:{sc}] {fa}({fs}) -> {c_esc}", flush=True)
    # CC harness idle-wakeup bridge: emit a second line whose prefix matches the
    # inter-session monitor's stdout pattern. fa/mid sanitized so injected
    # quotes/brackets can't break downstream parsers (cursor-agent review MED).
    import re as _re
    fa_safe = _re.sub(r'[^A-Za-z0-9._-]', '_', fa)[:32] or "unknown"
    mid_safe = _re.sub(r'[^A-Za-z0-9._-]', '_', mid)[:16] or "noid"
    print(f'[inter-session msg=mesh:{mid_safe} from="{fa_safe}"] {c_esc}', flush=True)
PYEOF
  sleep "$INTERVAL"
done
