# 단일 AI에 작업을 위임합니다.
# $ARGUMENTS의 첫 단어=AI 이름, 나머지=프롬프트로 파싱해 NCO 서버에 POST한다.
# 형식: /nco-task <AI이름> <작업내용>
# 예: /nco-task codex auth 모듈에 JWT 검증 추가
#
# 2026-07-09 수정(claude-1 발견): 이 파일이 과거 `nco-task $ARGUMENTS`(존재하지 않는
# 바이너리/MCP 도구를 가리키는 미완성 스텁)였음 — 실행해도 아무 것도 전송되지 않고
# echo만 됨. NCO_사용률 트래커가 항상 0%였던 원인. nco-commander.md/nco-conductor.md의
# 검증된 curl 패턴을 그대로 적용해 실제 POST /api/task 로 수정.

_ARGS="$ARGUMENTS"
AI=$(printf '%s' "$_ARGS" | cut -d' ' -f1)
PROMPT=$(printf '%s' "$_ARGS" | cut -d' ' -f2-)

if [ -z "$AI" ] || [ -z "$PROMPT" ] || [ "$AI" = "$PROMPT" ]; then
  echo "[오류] 형식: /nco-task <AI이름> <작업내용>  예: /nco-task codex auth 모듈에 JWT 검증 추가"
else
  jq -n --arg ai "$AI" --arg prompt "$PROMPT" --arg pd "$PWD" \
    '{"ai":$ai,"callerAgentId":"claude-commander","prompt":$prompt,"metadata":{"allowProviderFailover":true,"projectDir":$pd}}' \
    | curl -s -X POST http://localhost:6200/api/task \
        -H "Content-Type: application/json" \
        --data-binary @- \
    | python3 -m json.tool 2>/dev/null || echo "[오류] NCO 서버 응답 없음 — /nco-start 로 NCO를 먼저 시작하세요."
fi
