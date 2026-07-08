#!/bin/bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작 (2026-07-08, 76s 훅스택+BOOTSTRAP 오염 T1)
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
# mesh-delegate.sh — Send a TASK delegation via NCO Mesh.
# Wraps content as JSON envelope so receiver can extract taskId/instructions/depth.
#
# Usage:
#   mesh-delegate.sh <toAgent> <title> <instructions> [depth=0]
#
# Env:
#   NCO_SESSION_ID, NCO_NAME  (set by session-start.sh)
#
# Stdout: taskId on success
# Exit:  0 delivered | 1 send failed | 2 bad args

set -euo pipefail

if [ $# -lt 3 ]; then
  echo "usage: mesh-delegate.sh <toAgent> <title> <instructions> [depth=0]" >&2
  exit 2
fi

TO="${1#@}"
TITLE="$2"
INSTRUCTIONS="$3"
DEPTH="${4:-0}"

FROM_AGENT="${NCO_NAME:-claude-code}"
FROM_SID="${NCO_SESSION_ID:-$$}"
TASK_ID="t-$(date +%s)-$RANDOM"

# JSON envelope so receiver parses cleanly
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

# Delegate via mesh-send with type=task (mesh-send.sh handles sid lookup + delivery)
if "$HOME/.claude/hooks/mesh-send.sh" "$TO" "$CONTENT" task >/dev/null; then
  echo "$TASK_ID"
  exit 0
else
  echo "[mesh-delegate] send failed: from=$FROM_AGENT to=$TO task=$TASK_ID" >&2
  exit 1
fi
