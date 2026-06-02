# 에이전트 세션을 관리합니다.
# $ARGUMENTS로 동작을 지정합니다.

# 사용법:
#   /nco-agent start <provider> <프롬프트>  — 세션 시작
#   /nco-agent list                        — 활성 세션 목록
#   /nco-agent abort <sessionId>           — 세션 중단
#   /nco-agent approve <sessionId>         — 도구 호출 승인
#   /nco-agent reject <sessionId>          — 도구 호출 거부

# 예: /nco-agent start codex "테스트 코드 작성"

# $ARGUMENTS를 안전하게 파싱 (한국어/특수문자 포함 시 bash 메타문자 오류 방지)
_ARGS="$ARGUMENTS"
ACTION=$(printf '%s' "$_ARGS" | cut -d' ' -f1)
case "$ACTION" in
  start)
    PROVIDER=$(printf '%s' "$_ARGS" | cut -d' ' -f2)
    PROMPT=$(printf '%s' "$_ARGS" | cut -d' ' -f3-)
    jq -n --arg provider "$PROVIDER" --arg prompt "$PROMPT" \
      '{"provider":$provider,"prompt":$prompt}' \
      | curl -s -X POST http://localhost:6200/api/agent/start \
          -H "Content-Type: application/json" \
          --data-binary @- \
      | python3 -m json.tool
    ;;
  list)
    curl -s http://localhost:6200/api/agent/sessions | python3 -m json.tool
    ;;
  abort|approve|reject)
    SID=$(printf '%s' "$_ARGS" | cut -d' ' -f2)
    curl -s -X POST "http://localhost:6200/api/agent/$SID/$ACTION" \
      -H "Content-Type: application/json" -d '{}' | python3 -m json.tool
    ;;
  *)
    echo "Unknown action: $ACTION. Use: start, list, abort, approve, reject"
    ;;
esac
