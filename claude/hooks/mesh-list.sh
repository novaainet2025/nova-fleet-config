#!/bin/bash
# mesh-list.sh — List active Mesh sessions.
# Mirrors inter-session's list.py.
#
# Usage:
#   mesh-list.sh           # all sessions
#   mesh-list.sh --self    # just this session
#
# Output (one session per line):
#   <agentId>  <status>  <branch>  <currentWork>  last=<heartbeat>

set -euo pipefail

API="${NCO_API:-http://localhost:6200}"
SELF_ONLY=0
[ "${1:-}" = "--self" ] && SELF_ONLY=1

RESP=$(curl -s --max-time 6 "${API}/api/mesh/sessions" 2>/dev/null || echo '{}')

ME_SID="${NCO_SESSION_ID:-$$}"
ME_NAME="${NCO_NAME:-claude-code}"

RESP="$RESP" ME_SID="$ME_SID" ME_NAME="$ME_NAME" SELF_ONLY="$SELF_ONLY" python3 <<'PYEOF'
import json, sys, os
from datetime import datetime, timezone

me_sid    = os.environ.get("ME_SID", "")
me_name   = os.environ.get("ME_NAME", "")
self_only = os.environ.get("SELF_ONLY", "0") == "1"
resp      = os.environ.get("RESP", "")

try:
    d = json.loads(resp)
except Exception as e:
    print(f"[mesh-list] failed to parse NCO response: {e}", file=sys.stderr)
    sys.exit(1)

sessions = d.get("sessions", [])
if not sessions:
    print("[mesh-list] no active sessions")
    sys.exit(0)

now = datetime.now(timezone.utc)
rows = []
for s in sessions:
    sid = str(s.get("sessionId", ""))
    name = s.get("agentId", "?")
    if self_only and not (sid == me_sid or name == me_name):
        continue
    is_me = (sid == me_sid or name == me_name)
    status = s.get("status", "?")
    branch = s.get("branch", "")
    work = (s.get("currentWork", "") or "")[:40]
    hb = s.get("lastHeartbeat", "")
    age = "?"
    try:
        t = datetime.fromisoformat(hb.replace("Z", "+00:00"))
        delta = (now - t).total_seconds()
        age = f"{int(delta)}s" if delta < 60 else f"{int(delta//60)}m"
    except Exception:
        pass
    marker = "*" if is_me else " "
    rows.append(f"{marker} {name:<14} {status:<8} {branch:<10} {work:<40} last={age}")

if not rows:
    print("[mesh-list] (filtered: no matching sessions)")
else:
    for r in rows:
        print(r)
PYEOF
