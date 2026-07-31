# 새 Plan을 생성합니다. 토론 결과를 기반으로 자동 태스크 분해 + docs/plans/ 마크다운 파일을 생성합니다.
# $ARGUMENTS를 Plan 제목으로 사용합니다.
# 형식: /nco-plan <Plan 제목>

if [ -z "$ARGUMENTS" ]; then
  echo "사용법: /nco-plan <Plan 제목>"
  exit 1
fi

jq -n --arg title "$ARGUMENTS" '{"title":$title}' \
  | curl -s -X POST http://localhost:6200/api/plan/create \
      -H "Content-Type: application/json" \
      --data-binary @- \
  | python3 -m json.tool
