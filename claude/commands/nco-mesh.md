# CLI Mesh — Multi-agent state & sync
# /nco-mesh [done|check|send|messages|ping]

# Identity
MY_NAME="claude-code"
# Try to find current agent name from PID
for f in /tmp/nco-names/*.pid; do
  [ "$(cat $f 2>/dev/null)" = "$PPID" ] && MY_NAME=$(basename $f .pid) && break
done
# Persistent Session ID
_SID_FILE="/tmp/nco-names/$MY_NAME-$PPID.sid"
mkdir -p /tmp/nco-names
[ -f "$_SID_FILE" ] || python3 -c "import uuid; print('$MY_NAME-'+uuid.uuid4().hex[:8])" > "$_SID_FILE"
MY_SESSION_ID=$(cat "$_SID_FILE")

case "$1" in
  done)
    curl -s -X POST http://localhost:6200/api/mesh/complete -H "Content-Type: application/json" -d "{\"sessionId\":\"$MY_SESSION_ID\",\"completedWork\":\"${2:-Done}\"}" | python3 -c "import sys,json; print('✓ Done:', sys.stdin.read())"
    ;;
  check)
    curl -s -X POST http://localhost:6200/api/mesh/check -H "Content-Type: application/json" -d "{\"sessionId\":\"$MY_SESSION_ID\",\"agentId\":\"$MY_NAME\",\"plannedWork\":\"$2\",\"plannedFiles\":[],\"branch\":\"$(git rev-parse --abbrev-ref HEAD 2>/dev/null)\"}" | python3 -c "import sys,json; d=json.load(sys.stdin); print('Safe:', d.get('safe')); [print(r['detail']) for r in d.get('conflictReports',[])]"
    ;;
  send)
    TO="*"; MSG="$2"; [[ "$2" == @* ]] && TO="${2#@}" && TO="${TO%% *}" && MSG="${2#* }"
    curl -s -X POST http://localhost:6200/api/mesh/send -H "Content-Type: application/json" -d "{\"fromSessionId\":\"$MY_SESSION_ID\",\"fromAgent\":\"$MY_NAME\",\"toSessionId\":\"$TO\",\"content\":\"$MSG\"}" | python3 -c "import sys,json; print('Sent:', json.load(sys.stdin).get('delivered'))"
    ;;
  messages)
    curl -s "http://localhost:6200/api/mesh/messages/$MY_SESSION_ID?drain=1" | python3 -c "import sys,json; d=json.load(sys.stdin); [print(f'[{m.get(\"fromAgent\")}] {m.get(\"content\")}') for m in d.get('pending',[])+d.get('messages',[])[:5]]"
    ;;
  ping)
    curl -s -X POST http://localhost:6200/api/mesh/heartbeat -H "Content-Type: application/json" -d "{\"sessionId\":\"$MY_SESSION_ID\",\"agentId\":\"$MY_NAME\",\"pid\":$PPID,\"status\":\"idle\",\"currentWork\":\"Active\"}" | python3 -m json.tool
    ;;
  *)
    curl -s http://localhost:6200/api/mesh/sessions | python3 -c "import sys,json; d=json.load(sys.stdin); [print(f\"[{s.get('agentId')}] {s.get('status')} {s.get('currentWork')}\") for s in d.get('sessions',[])]"
    ;;
esac
