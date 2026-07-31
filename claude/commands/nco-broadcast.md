# 전체 AI에 메시지를 브로드캐스트합니다.
# 사용법: /nco-broadcast <메시지>
# 예: /nco-broadcast "PR 리뷰 완료 — 다음 단계로 이동"

MSG="$ARGUMENTS"
if [ -z "$MSG" ]; then
  echo "[오류] 메시지를 입력하세요."
  exit 1
fi

# /api/chat/messages 가 아니라 /api/broadcast 로 보낸다.
# chat/messages 핸들러는 body.message 와 body.ai 만 읽고 broadcast 플래그는 무시하므로
# 기본 에이전트 1개에게만 전달됐다(브로드캐스트가 아니었다).
# /api/broadcast 는 agentManager.listEnabledIds() 전체로 팬아웃한다.
curl -s -X POST http://localhost:6200/api/broadcast \
  -H "Content-Type: application/json" \
  -d "{\"message\": $(printf '%s' "$MSG" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')}" \
  | python3 -m json.tool 2>/dev/null || echo "[오류] NCO 서버 응답 없음."
