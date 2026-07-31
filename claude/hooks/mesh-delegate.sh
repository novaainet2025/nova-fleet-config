#!/bin/bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작 (2026-07-08, 76s 훅스택+BOOTSTRAP 오염 T1)
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
# mesh-delegate.sh — Send a TASK delegation via NCO Mesh.
# Wraps content as JSON envelope so receiver can extract taskId/instructions/depth.

set -euo pipefail

if [ $# -lt 3 ]; then
  echo "usage: mesh-delegate.sh <toAgent> <title> <instructions> [depth=0]" >&2
  exit 2
fi

TO="${1#@}"
TITLE="$2"
INSTRUCTIONS="$3"
DEPTH="${4:-0}"

API="${NCO_API:-http://localhost:6200}"
FROM_AGENT="${NCO_NAME:-claude-code}"
FROM_SID="${NCO_SESSION_ID:-$$}"
TASK_ID="t-$(date +%s)-$RANDOM"

resolve_to_sid() {
  local to="$1"
  if [ "$to" = "*" ]; then
    printf '*'
    return 0
  fi
  if printf '%s' "$to" | grep -Eq '^[0-9]+$'; then
    printf '%s' "$to"
    return 0
  fi
  TO="$to" API="$API" python3 <<'PY'
import json
import os
import subprocess
import sys
import time
import urllib.request

api = os.environ["API"]
target = os.environ["TO"]

try:
    raw = urllib.request.urlopen(f"{api}/api/mesh/sessions", timeout=4).read().decode()
    data = json.loads(raw)
except Exception:
    raise SystemExit(0)

cands = [s for s in data.get("sessions", []) if s.get("agentId") == target]
cands.sort(key=lambda s: s.get("lastHeartbeat", ""), reverse=True)
now = time.time()

for sess in cands:
    sid = str(sess.get("sessionId", ""))
    if not sid:
        continue
    try:
        with open(f"/tmp/nco-inbox-{sid}/poller.pid") as fh:
            pid = int(fh.read().strip())
        os.kill(pid, 0)
        print(sid)
        raise SystemExit(0)
    except Exception:
        pass

for sess in cands:
    sid = str(sess.get("sessionId", ""))
    if not sid:
        continue
    try:
        if now - os.stat(f"/tmp/nco-inbox-{sid}/queue.log").st_mtime <= 60:
            print(sid)
            raise SystemExit(0)
    except Exception:
        pass
PY
}

send_payload() {
  local payload="$1"
  curl -s --max-time 8 -X POST "${API}/api/mesh/send" \
    -H 'Content-Type: application/json' \
    -d "$payload" 2>/dev/null || echo '{}'
}

lookup_message_id() {
  local to_sid="$1"
  local content="$2"
  local attempt="${3:-5}"
  local idx=0
  while [ "$idx" -lt "$attempt" ]; do
    idx=$((idx + 1))
    RESP=$(curl -s --max-time 4 "${API}/api/mesh/messages?limit=50" 2>/dev/null || echo "")
    if [ -n "$RESP" ]; then
      found=$(RESP="$RESP" FROM_SID="$FROM_SID" TO_SID="$to_sid" CONTENT="$content" python3 <<'PY'
import json
import os

resp = os.environ.get("RESP", "")
from_sid = os.environ.get("FROM_SID", "")
to_sid = os.environ.get("TO_SID", "")
content = os.environ.get("CONTENT", "")

try:
    data = json.loads(resp)
except Exception:
    raise SystemExit(0)

for item in data.get("messages", []):
    if str(item.get("from_session", "")) != from_sid:
        continue
    if str(item.get("to_session", "")) != to_sid:
        continue
    if (item.get("content", "") or "") != content:
        continue
    print(item.get("id", ""))
    break
PY
)
      if [ -n "$found" ]; then
        printf '%s' "$found"
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

wait_for_ack() {
  local msg_id="$1"
  local to_sid="$2"
  local limit="${3:-30}"
  local waited=0
  while [ "$waited" -lt "$limit" ]; do
    RESP=$(curl -s --max-time 4 "${API}/api/mesh/messages?limit=60" 2>/dev/null || echo "")
    if [ -n "$RESP" ]; then
      ack=$(RESP="$RESP" MSG_ID="$msg_id" FROM_SID="$FROM_SID" TO_SID="$to_sid" TO_AGENT="$TO" python3 <<'PY'
import json
import os

resp = os.environ.get("RESP", "")
msg_id = os.environ.get("MSG_ID", "")
from_sid = os.environ.get("FROM_SID", "")
to_sid = os.environ.get("TO_SID", "")
to_agent = os.environ.get("TO_AGENT", "")

try:
    data = json.loads(resp)
except Exception:
    raise SystemExit(0)

needle = f"ack: {msg_id} "
for item in data.get("messages", []):
    if str(item.get("to_session", "")) != from_sid:
      continue
    sender_sid = str(item.get("from_session", ""))
    sender_agent = str(item.get("from_agent", ""))
    if sender_sid != to_sid and sender_agent != to_agent:
      continue
    content = (item.get("content", "") or "")
    if content.startswith(needle):
      print(content)
      break
PY
)
      if [ -n "$ack" ]; then
        return 0
      fi
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

TO_SID="$(resolve_to_sid "$TO")"
if [ -z "$TO_SID" ]; then
  echo "[mesh-delegate] agent '${TO}' has no live session" >&2
  exit 1
fi

CONTENT=$(TASK_ID="$TASK_ID" TITLE="$TITLE" INSTR="$INSTRUCTIONS" DEPTH="$DEPTH" REPLY="$FROM_AGENT" python3 -c '
import json, os
print(json.dumps({
  "taskId": os.environ["TASK_ID"],
  "title":  os.environ["TITLE"],
  "instructions": os.environ["INSTR"],
  "depth":  int(os.environ["DEPTH"]),
  "replyTo": os.environ["REPLY"],
}, ensure_ascii=False))
')

PAYLOAD=$(FROM_SID="$FROM_SID" FROM_AGENT="$FROM_AGENT" TO="$TO" TO_SID="$TO_SID" TEXT="$CONTENT" python3 -c '
import json, os
print(json.dumps({
  "fromSessionId": os.environ["FROM_SID"],
  "fromAgent": os.environ["FROM_AGENT"],
  "toSessionId": os.environ["TO_SID"],
  "toAgent": os.environ["TO"],
  "content": os.environ["TEXT"],
  "type": "task",
}, ensure_ascii=False))
')

RESP=$(send_payload "$PAYLOAD")
DELIVERED=$(printf '%s' "$RESP" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); print(d.get("delivered", 0))
except Exception: print(0)' 2>/dev/null)

if ! [ "${DELIVERED:-0}" -ge 1 ] 2>/dev/null; then
  echo "[mesh-delegate] send failed: from=$FROM_AGENT to=$TO task=$TASK_ID" >&2
  exit 1
fi

echo "$TASK_ID"

MSG_ID="$(lookup_message_id "$TO_SID" "$CONTENT" 5 || true)"
if [ -n "$MSG_ID" ] && wait_for_ack "$MSG_ID" "$TO_SID" 30; then
  exit 0
fi

RESP=$(send_payload "$PAYLOAD")
DELIVERED=$(printf '%s' "$RESP" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); print(d.get("delivered", 0))
except Exception: print(0)' 2>/dev/null)

if ! [ "${DELIVERED:-0}" -ge 1 ] 2>/dev/null; then
  echo "delivery-unconfirmed taskId=$TASK_ID to=$TO"
  exit 0
fi

MSG_ID="$(lookup_message_id "$TO_SID" "$CONTENT" 5 || true)"
if [ -n "$MSG_ID" ] && wait_for_ack "$MSG_ID" "$TO_SID" 30; then
  exit 0
fi

echo "delivery-unconfirmed taskId=$TASK_ID to=$TO"
exit 0
