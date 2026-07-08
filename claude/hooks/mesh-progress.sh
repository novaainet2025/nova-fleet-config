#!/bin/bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작 (2026-07-08, 76s 훅스택+BOOTSTRAP 오염 T1)
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
# mesh-progress.sh — Stream a task progress update back to the delegator.
#
# Usage:
#   mesh-progress.sh <toAgent> <taskId> <percent> <message>
#
# Emits a `status: [<taskId>] <percent>% - <message>` DM so the originator's
# inbox-poller surfaces it as a system reminder.
#
# Exit: 0 delivered | 1 send failed | 2 bad args

set -euo pipefail

if [ $# -lt 4 ]; then
  echo "usage: mesh-progress.sh <toAgent> <taskId> <percent> <message>" >&2
  exit 2
fi

TO="${1#@}"
TASK_ID="$2"
PCT="$3"
MSG="$4"

TEXT="status: [${TASK_ID}] ${PCT}% - ${MSG}"

if [ -x "$HOME/.claude/hooks/mesh-send.sh" ]; then
  exec "$HOME/.claude/hooks/mesh-send.sh" "$TO" "$TEXT" info
fi

# Fallback: raw curl (used if mesh-send.sh missing)
API="${NCO_API:-http://localhost:6200}"
FROM_AGENT="${NCO_NAME:-claude-code}"
FROM_SID="${NCO_SESSION_ID:-$$}"
PAYLOAD=$(FROM_SID="$FROM_SID" FROM_AGENT="$FROM_AGENT" TO="$TO" TEXT="$TEXT" python3 -c '
import json, os
print(json.dumps({
  "fromSessionId": os.environ["FROM_SID"],
  "fromAgent":     os.environ["FROM_AGENT"],
  "toAgent":       os.environ["TO"],
  "content":       os.environ["TEXT"],
  "type":          "info",
}, ensure_ascii=False))
')
curl -s --max-time 5 -X POST "${API}/api/mesh/send" \
  -H 'Content-Type: application/json' -d "$PAYLOAD" >/dev/null
