# AI 에이전트 리더보드를 조회합니다. 성공률, 태스크 수, 평균 응답 시간을 표시합니다.

curl -s http://localhost:6200/api/observability/leaderboard | python3 -m json.tool
