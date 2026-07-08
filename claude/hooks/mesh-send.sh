#!/bin/bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작 (2026-07-08, 76s 훅스택+BOOTSTRAP 오염 T1)
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
# mesh-send.sh — Send a DM via NCO Mesh REST API.
# Mirrors inter-session's send.py.
#
# Usage:
#   mesh-send.sh <toAgent>   '<text>'        # DM
#   mesh-send.sh @<toAgent>  '<text>'        # @-prefix tolerated
#
# Env (set by session-start.sh):
#   NCO_SESSION_ID  — sender's session id
#   NCO_NAME        — sender's agent name (claude-N)
#
# Exit codes:
#   0  delivered>=1
#   1  delivery failed or NCO offline
#   2  bad arguments

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage: mesh-send.sh <toAgent> '<text>'" >&2
  exit 2
fi

TO="${1#@}"
TEXT="$2"
TYPE="${3:-info}"
API="${NCO_API:-http://localhost:6200}"
FROM_SID="${NCO_SESSION_ID:-$$}"
FROM_AGENT="${NCO_NAME:-claude-code}"

# Resolve toSessionId from agent name (NCO API에서 toAgent는 '*'로 저장돼서 unicast 안됨,
# toSessionId 필드만 실제 라우팅됨 — mesh-auto-responder.js:430 sendReply와 동일 패턴).
# - 숫자면 그대로 sessionId
# - '*'면 broadcast (toAgent='*' 필드 사용)
# - 그 외 agent name이면 /api/mesh/sessions에서 lookup
TO_SID=""
if [ "$TO" = "*" ]; then
  TO_SID="*"
elif [[ "$TO" =~ ^[0-9]+$ ]]; then
  TO_SID="$TO"
else
  # Live-sid resolver: NCO /api/mesh/sessions가 stale sid를 캐시하므로
  # 로컬 신호(poller.pid alive → queue.log mtime ≤60s)로 좀비 sid 필터.
  # cursor-agent 알고리즘 (2026-05-26 nco-discussion 합의).
  TO_SID=$(curl -s --max-time 4 "${API}/api/mesh/sessions" 2>/dev/null \
    | TO="$TO" python3 -c '
import json,sys,os,time
target=os.environ["TO"]
try:
  d=json.load(sys.stdin)
  cands=[s for s in d.get("sessions",[]) if s.get("agentId")==target]
  cands.sort(key=lambda s: s.get("lastHeartbeat",""), reverse=True)
  now=time.time()
  # 1st pass: poller.pid alive
  for s in cands:
    sid=str(s.get("sessionId",""))
    if not sid: continue
    try:
      with open(f"/tmp/nco-inbox-{sid}/poller.pid") as f: p=int(f.read().strip())
      os.kill(p,0); print(sid); sys.exit(0)
    except Exception: continue
  # 2nd pass: queue.log mtime ≤ 60s
  for s in cands:
    sid=str(s.get("sessionId",""))
    try:
      if now-os.stat(f"/tmp/nco-inbox-{sid}/queue.log").st_mtime <= 60:
        print(sid); sys.exit(0)
    except Exception: continue
except Exception: pass')
  if [ -z "$TO_SID" ]; then
    echo "[mesh-send] agent '${TO}' has no live session (poller.pid dead + queue mtime > 60s)" >&2
    exit 1
  fi
fi

PAYLOAD=$(FROM_SID="$FROM_SID" FROM_AGENT="$FROM_AGENT" TO="$TO" TO_SID="$TO_SID" TEXT="$TEXT" TYPE="$TYPE" python3 -c '
import json, os
to_sid = os.environ["TO_SID"]
out = {
    "fromSessionId": os.environ["FROM_SID"],
    "fromAgent":     os.environ["FROM_AGENT"],
    "content":       os.environ["TEXT"],
    "type":          os.environ["TYPE"],
}
# broadcast는 toAgent="*", unicast는 toSessionId
if to_sid == "*":
    out["toAgent"] = "*"
else:
    out["toSessionId"] = to_sid
    out["toAgent"]     = os.environ["TO"]  # 표시용
print(json.dumps(out, ensure_ascii=False))
')

RESP=$(curl -s --max-time 8 -X POST "${API}/api/mesh/send" \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD" 2>/dev/null || echo '{}')

DELIVERED=$(echo "$RESP" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); print(d.get("delivered", 0))
except: print(0)' 2>/dev/null)

if [ "${DELIVERED:-0}" -ge 1 ] 2>/dev/null; then
  echo "[mesh-send] ${FROM_AGENT} -> ${TO}: delivered=${DELIVERED}"
  exit 0
else
  echo "[mesh-send] ${FROM_AGENT} -> ${TO}: FAILED (resp=${RESP})" >&2
  exit 1
fi
