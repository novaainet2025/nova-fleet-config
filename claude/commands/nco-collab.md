# NCO 그룹 지성 협업 세션을 관리합니다 (생성, 참여, 기여, 투표, 종료).

BASE="http://localhost:6200"
ACTION="${1:-list}"

case "$ACTION" in
  create)
    # nco-collab create <title> [type]
    TITLE="${2:-협업 세션}"
    TYPE="${3:-brainstorm}"
    SESSION_ID="${NCO_SESSION_ID:-$(hostname)-$$}"
    curl -s -X POST "$BASE/api/collab/create" \
      -H "Content-Type: application/json" \
      -d "{\"creatorSessionId\":\"$SESSION_ID\",\"creatorAgentId\":\"claude-code\",\"title\":\"$TITLE\",\"type\":\"$TYPE\"}" \
      | python3 -m json.tool
    ;;
  join)
    # nco-collab join <collab-id>
    COLLAB_ID="$2"
    SESSION_ID="${NCO_SESSION_ID:-$(hostname)-$$}"
    curl -s -X POST "$BASE/api/collab/$COLLAB_ID/join" \
      -H "Content-Type: application/json" \
      -d "{\"sessionId\":\"$SESSION_ID\",\"agentId\":\"claude-code\"}" \
      | python3 -m json.tool
    ;;
  contribute|add)
    # nco-collab contribute <collab-id> <content>
    COLLAB_ID="$2"
    CONTENT="${3:-}"
    SESSION_ID="${NCO_SESSION_ID:-$(hostname)-$$}"
    curl -s -X POST "$BASE/api/collab/$COLLAB_ID/contribute" \
      -H "Content-Type: application/json" \
      -d "{\"sessionId\":\"$SESSION_ID\",\"agentId\":\"claude-code\",\"content\":\"$CONTENT\"}" \
      | python3 -m json.tool
    ;;
  vote)
    # nco-collab vote <contribution-id> <1|-1>
    CONTRIB_ID="$2"
    VOTE="${3:-1}"
    SESSION_ID="${NCO_SESSION_ID:-$(hostname)-$$}"
    COLLAB_ID="${4:-unknown}"
    curl -s -X POST "$BASE/api/collab/$COLLAB_ID/vote" \
      -H "Content-Type: application/json" \
      -d "{\"contributionId\":\"$CONTRIB_ID\",\"voterSessionId\":\"$SESSION_ID\",\"vote\":$VOTE}" \
      | python3 -m json.tool
    ;;
  voting)
    # nco-collab voting <collab-id>
    COLLAB_ID="$2"
    curl -s -X POST "$BASE/api/collab/$COLLAB_ID/voting" \
      -H "Content-Type: application/json" \
      -d '{}' | python3 -m json.tool
    ;;
  close)
    # nco-collab close <collab-id> [result]
    COLLAB_ID="$2"
    RESULT="${3:-}"
    curl -s -X POST "$BASE/api/collab/$COLLAB_ID/close" \
      -H "Content-Type: application/json" \
      -d "{\"result\":\"$RESULT\"}" \
      | python3 -m json.tool
    ;;
  show)
    # nco-collab show <collab-id>
    COLLAB_ID="$2"
    curl -s "$BASE/api/collab/$COLLAB_ID" | python3 -c "
import sys, json
d = json.load(sys.stdin)
c = d.get('collab', {})
print(f'ID     : {c.get(\"id\",\"-\")}')
print(f'제목   : {c.get(\"title\",\"-\")}')
print(f'타입   : {c.get(\"type\",\"-\")}')
print(f'상태   : {c.get(\"status\",\"-\")}')
print(f'참여자 : {len(c.get(\"participantSessionIds\",[]))}명')
print(f'결과   : {c.get(\"result\") or \"(미정)\"}')
print()
contribs = d.get('contributions', [])
print(f'기여 목록 ({len(contribs)}개):')
for i, ct in enumerate(contribs, 1):
    print(f'  [{i}] {ct[\"id\"][:10]}  score={ct[\"score\"]}  {ct[\"content\"][:60]}')
"
    ;;
  open|list)
    curl -s "$BASE/api/collab/open" | python3 -c "
import sys, json
d = json.load(sys.stdin)
collabs = d.get('collaborations', [])
if not collabs:
    print('진행 중인 협업 없음')
else:
    print(f'진행 중인 협업 ({len(collabs)}개):')
    for c in collabs:
        pts = len(c.get('participantSessionIds', []))
        print(f'  {c[\"id\"][:14]}  [{c[\"type\"]}] {c[\"title\"]}  참여자={pts}  상태={c[\"status\"]}')
"
    ;;
  *)
    echo "사용법: nco-collab <create|join|contribute|vote|voting|close|show|list>"
    echo "  create   <title> [type]         새 협업 세션 생성"
    echo "  join     <id>                   협업 참여"
    echo "  contribute <id> <content>       아이디어/결과 제출"
    echo "  vote     <contrib-id> <1|-1> <collab-id>  투표"
    echo "  voting   <id>                   투표 단계 시작"
    echo "  close    <id> [result]          협업 종료"
    echo "  show     <id>                   상세 보기"
    echo "  list                            진행 중인 협업 목록"
    ;;
esac
