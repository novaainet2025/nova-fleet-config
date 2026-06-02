# Hive 모드 — 전체 9개 AI를 하나처럼 실행합니다.
# 사용법: /nco-hive <프롬프트>
# 예: /nco-hive "이 시스템의 보안 취약점을 모두 찾아라"

PROMPT="$ARGUMENTS"
if [ -z "$PROMPT" ]; then
  echo "[오류] 프롬프트를 입력하세요."
  echo "예: /nco-hive \"복잡한 문제 설명\""
  exit 1
fi

echo "🐝 Hive 모드 시작 — 9개 AI 동시 투입..."
curl -s -X POST http://localhost:6200/api/realtime/discussion \
  -H "Content-Type: application/json" \
  -d "{\"prompt\": $(echo "$PROMPT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))'), \"mode\": \"hive\"}" \
  | python3 -m json.tool 2>/dev/null || echo "[오류] NCO 서버 응답 없음 — /nco-start 로 NCO를 먼저 시작하세요."
