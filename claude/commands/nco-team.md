# 여러 에이전트를 병렬로 실행합니다.
# $ARGUMENTS로 프롬프트를 지정합니다.

# 사용법:
#   /nco-team <프롬프트>                    — 자동 에이전트 배분 (conductor)
#   /nco-team parallel <프롬프트>           — 병렬 실행
#   /nco-team consensus <프롬프트>          — 합의 도출

# 예: /nco-team "인증 모듈 설계 검토"

_ARGS="$ARGUMENTS"
MODE=$(printf '%s' "$_ARGS" | cut -d' ' -f1)
case "$MODE" in
  parallel)
    PROMPT=$(printf '%s' "$_ARGS" | cut -d' ' -f2-)
    jq -n --arg prompt "$PROMPT" '{"prompt":$prompt}' \
      | curl -s -X POST http://localhost:6200/api/parallel \
          -H "Content-Type: application/json" \
          --data-binary @- \
      | python3 -m json.tool
    ;;
  consensus)
    PROMPT=$(printf '%s' "$_ARGS" | cut -d' ' -f2-)
    jq -n --arg prompt "$PROMPT" '{"prompt":$prompt}' \
      | curl -s -X POST http://localhost:6200/api/consensus \
          -H "Content-Type: application/json" \
          --data-binary @- \
      | python3 -m json.tool
    ;;
  *)
    # 기본: conductor (자동 에이전트 선택)
    PROMPT="$_ARGS"
    jq -n --arg prompt "$PROMPT" '{"prompt":$prompt}' \
      | curl -s -X POST http://localhost:6200/api/conductor \
          -H "Content-Type: application/json" \
          --data-binary @- \
      | python3 -m json.tool
    ;;
esac
