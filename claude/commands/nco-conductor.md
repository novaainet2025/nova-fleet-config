# Smart Router가 복잡도를 분석하고 최적 모드+AI를 자동 선택하여 실행합니다.
# $ARGUMENTS를 프롬프트로 사용합니다.
# 형식: /nco-conductor <작업 설명>

curl -s -X POST http://localhost:6200/api/conductor \
  -H "Content-Type: application/json" \
  -d "{\"prompt\":\"$ARGUMENTS\"}" | python3 -m json.tool
