# CLI 세션 간 작업 위임 명령어.
# 사용법:
#   /nco-delegate @claude-2 "작업 제목" "설명(선택)"  → 위임 요청
#   /nco-delegate list                                → 내 위임 목록
#   /nco-delegate accept <id>                         → 수락
#   /nco-delegate reject <id> [이유]                  → 거절
#   /nco-delegate done <id> [결과]                    → 완료 보고
#   /nco-delegate progress <id> <0-100> [메모]        → 진행상황 업데이트

PORT=6200
SESSION_ID="${NCO_SESSION_ID:-unknown}"
ARGS="${ARGUMENTS:-}"
CMD=$(echo "$ARGS" | awk '{print $1}')

case "$CMD" in
  list)
    curl -s "http://localhost:${PORT}/api/mesh/delegations/session/${SESSION_ID}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
incoming=d.get('incoming',[])
outgoing=d.get('outgoing',[])
print('=== 받은 위임 ===')
for dl in incoming:
    status_map={'pending':'⏳','accepted':'✅','rejected':'❌','expired':'⌛'}
    w_map={'waiting':'대기','in_progress':'진행중','completed':'완료','failed':'실패','cancelled':'취소'}
    print(f'  [{dl[\"id\"]}] {dl[\"fromAgentId\"]} → 나: {dl[\"title\"]}')
    print(f'    수락: {status_map.get(dl[\"acceptanceStatus\"],\"?\")}, 작업: {w_map.get(dl[\"workStatus\"],\"?\")} ({dl[\"progressPct\"]}%)')
if not incoming: print('  (없음)')
print()
print('=== 보낸 위임 ===')
for dl in outgoing:
    print(f'  [{dl[\"id\"]}] 나 → {dl[\"toAgentId\"]}: {dl[\"title\"]}')
    print(f'    수락: {dl[\"acceptanceStatus\"]}, 작업: {dl[\"workStatus\"]} ({dl[\"progressPct\"]}%)')
if not outgoing: print('  (없음)')
" 2>/dev/null || echo "NCO 서버 응답 없음"
    ;;
  accept)
    ID=$(echo "$ARGS" | awk '{print $2}')
    curl -s -X POST "http://localhost:${PORT}/api/mesh/delegations/${ID}/respond" \
      -H "Content-Type: application/json" \
      -d "{\"accept\":true,\"sessionId\":\"${SESSION_ID}\"}" | python3 -c "import sys,json; d=json.load(sys.stdin); print('✅ 위임 수락:', d.get('id', d.get('ok','')))"
    ;;
  reject)
    ID=$(echo "$ARGS" | awk '{print $2}')
    REASON=$(echo "$ARGS" | cut -d' ' -f3-)
    curl -s -X POST "http://localhost:${PORT}/api/mesh/delegations/${ID}/respond" \
      -H "Content-Type: application/json" \
      -d "{\"accept\":false,\"reason\":\"${REASON}\",\"sessionId\":\"${SESSION_ID}\"}" | python3 -c "import sys,json; d=json.load(sys.stdin); print('❌ 위임 거절:', d.get('id', d.get('ok','')))"
    ;;
  done)
    ID=$(echo "$ARGS" | awk '{print $2}')
    RESULT=$(echo "$ARGS" | cut -d' ' -f3-)
    curl -s -X POST "http://localhost:${PORT}/api/mesh/delegations/${ID}/complete" \
      -H "Content-Type: application/json" \
      -d "{\"result\":\"${RESULT}\",\"sessionId\":\"${SESSION_ID}\"}" | python3 -c "import sys,json; d=json.load(sys.stdin); print('✅ 위임 완료 보고:', d.get('id', d.get('ok','')))"
    ;;
  progress)
    ID=$(echo "$ARGS" | awk '{print $2}')
    PCT=$(echo "$ARGS" | awk '{print $3}')
    NOTE=$(echo "$ARGS" | cut -d' ' -f4-)
    curl -s -X POST "http://localhost:${PORT}/api/mesh/delegations/${ID}/progress" \
      -H "Content-Type: application/json" \
      -d "{\"pct\":${PCT:-0},\"note\":\"${NOTE}\",\"sessionId\":\"${SESSION_ID}\"}" | python3 -c "import sys,json; d=json.load(sys.stdin); print('📊 진행상황 업데이트:', d.get('id', d.get('ok','')))"
    ;;
  *)
    # 위임 요청: /nco-delegate @claude-2 "제목" "설명"
    TARGET=$(echo "$ARGS" | awk '{print $1}' | sed 's/@//')
    TITLE=$(echo "$ARGS" | grep -oP '"[^"]*"' | head -1 | tr -d '"')
    DESC=$(echo "$ARGS" | grep -oP '"[^"]*"' | tail -1 | tr -d '"')
    if [ -z "$TARGET" ] || [ -z "$TITLE" ]; then
      echo "사용법: /nco-delegate @세션명 \"작업 제목\" \"설명(선택)\""
      echo "       /nco-delegate list|accept|reject|done|progress ..."
      exit 1
    fi
    curl -s -X POST "http://localhost:${PORT}/api/mesh/delegate" \
      -H "Content-Type: application/json" \
      -d "{\"fromSessionId\":\"${SESSION_ID}\",\"toSessionId\":\"${TARGET}\",\"title\":\"${TITLE}\",\"description\":\"${DESC}\"}" | \
      python3 -c "import sys,json; d=json.load(sys.stdin); print(f'📤 위임 요청 전송: {d.get(\"delegationId\",\"\")} → ${TARGET}')"
    ;;
esac
