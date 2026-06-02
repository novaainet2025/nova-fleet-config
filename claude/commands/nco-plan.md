# 새 Plan을 생성합니다. 토론 결과를 기반으로 자동 태스크 분해 + docs/plans/ 마크다운 파일을 생성합니다.
# $ARGUMENTS를 Plan 제목으로 사용합니다.
# 형식: /nco-plan <Plan 제목>

# 1. 먼저 /nco-discussion으로 주제를 토론한다.
# 2. 토론 결과를 기반으로 Plan을 생성한다:

curl -s -X POST http://localhost:6200/api/plan/create \
  -H "Content-Type: application/json" \
  -d "{\"title\":\"$ARGUMENTS\"}" | python3 -m json.tool

3. 생성된 Plan의 docs/plans/<slug>.md 파일에 태스크 체크박스를 추가한다.
4. Stop Hook이 이 파일을 읽어 gap 분석에 반영한다.
