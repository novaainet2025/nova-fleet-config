# NCO 그룹 지성 협업 세션을 관리합니다 (생성, 참여, 기여, 투표, 종료).

BASE="http://localhost:6200"
ACTION="${1:-list}"

case "$ACTION" in
  create)
    # nco-collab create <title> [type]
    TITLE="${2:-협업 세션}"
    TYPE="${3:-brainstorm}"
    SESSION_ID="${NCO_SESSION_ID:-$(hostname)-$$}"
    # 생성 엔드포인트는 /api/collab/create 가 아니라 POST /api/collab 이다.
    # (create 경로는 서버에 없어서 catch-all 이 HTTP 200 스텁을 돌려주고 있었다.)
    # 스키마: {title, type?, description?, createdBy?} — creatorSessionId/creatorAgentId 는 없는 필드다.
    curl -s -X POST "$BASE/api/collab" \
      -H "Content-Type: application/json" \
      -d "{\"title\":\"$TITLE\",\"type\":\"$TYPE\",\"createdBy\":\"$SESSION_ID\"}" \
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
    # nco-collab vote <collab-id> <contribution-id> [1|-1]
    #
    # 2026-07-29 인자 순서 변경: 이전에는 <contrib-id> <1|-1> <collab-id> 였는데
    #  (a) join/contribute/close/show 는 전부 $2 가 collab-id 라 vote 만 달랐고
    #  (b) collab-id 를 생략하면 "unknown" 이 들어가 /api/collab/unknown/vote 로
    #      요청이 나가 무조건 실패했다(조용한 실패).
    # 이제 다른 액션과 순서를 통일하고 두 인자를 필수로 강제한다.
    COLLAB_ID="$2"
    CONTRIB_ID="$3"
    VOTE="${4:-1}"
    SESSION_ID="${NCO_SESSION_ID:-$(hostname)-$$}"
    if [ -z "$COLLAB_ID" ] || [ -z "$CONTRIB_ID" ]; then
      echo "사용법: nco-collab vote <collab-id> <contribution-id> [1|-1]"
      echo "  collab-id 와 contribution-id 는 필수입니다."
      echo "  기여 ID 는 'nco-collab show <collab-id>' 로 확인하세요."
      exit 1
    fi
    # 스키마는 {agentId, choice, vote?} 다. choice 가 투표 대상 기여 ID,
    # agentId 가 투표자다. 이전 필드명(contributionId/voterSessionId)은
    # 스키마에 없어서 항상 400 으로 떨어졌다.
    curl -s -X POST "$BASE/api/collab/$COLLAB_ID/vote" \
      -H "Content-Type: application/json" \
      -d "{\"choice\":\"$CONTRIB_ID\",\"agentId\":\"$SESSION_ID\",\"vote\":$VOTE}" \
      | python3 -m json.tool
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
    echo "사용법: nco-collab <create|join|contribute|vote|close|show|list>"
    echo "  create   <title> [type]         새 협업 세션 생성"
    echo "  join     <id>                   협업 참여"
    echo "  contribute <id> <content>       아이디어/결과 제출"
    echo "  vote     <collab-id> <contrib-id> [1|-1]  투표 (기본 1)"
    echo "                                  첫 투표 시 투표 단계가 자동 시작됨."
    echo "                                  투표 단계만 따로 여는 명령은 없습니다."
    echo "  close    <id> [result]          협업 종료"
    echo "  show     <id>                   상세 보기"
    echo "  list                            진행 중인 협업 목록"
    ;;
esac
