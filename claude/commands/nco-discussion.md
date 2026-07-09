# 멀티 AI 토론을 시작합니다.
# $ARGUMENTS를 토론 주제(topic)로 사용해 POST /api/discussion 을 호출한다.
# 형식: /nco-discussion <토론 주제>
#
# 2026-07-09 수정(claude-1 발견): 과거 `nco-discussion $ARGUMENTS`(미완성 스텁, 존재하지
# 않는 바이너리를 가리켜 echo만 되고 실제 전송 없음) — nco-team.md의 검증된 curl 패턴을
# 적용해 실제 POST /api/discussion 으로 수정. 서버 스키마(DiscussionRouteBodySchema)는
# topic 필드를 요구함(prompt 아님) — gateway.ts:1742-1769 확인.

TOPIC="$ARGUMENTS"

if [ -z "$TOPIC" ]; then
  echo "[오류] 형식: /nco-discussion <토론 주제>  예: /nco-discussion API 설계 REST vs GraphQL"
else
  jq -n --arg topic "$TOPIC" '{"topic":$topic}' \
    | curl -s -X POST http://localhost:6200/api/discussion \
        -H "Content-Type: application/json" \
        --data-binary @- \
    | python3 -m json.tool 2>/dev/null || echo "[오류] NCO 서버 응답 없음 — /nco-start 로 NCO를 먼저 시작하세요."
fi
