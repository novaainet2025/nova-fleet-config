# Commander 4-Layer 계층 실행을 시작합니다.
# Management → Information → Execution → Quality → Synthesis 순서로 9개 AI가 계층적으로 작업합니다.
# $ARGUMENTS를 프롬프트로 사용합니다.
# 형식: /nco-commander <작업 설명>

curl -s -X POST http://localhost:6200/api/commander \
  -H "Content-Type: application/json" \
  -d "{\"prompt\":\"$ARGUMENTS\"}" | python3 -m json.tool
