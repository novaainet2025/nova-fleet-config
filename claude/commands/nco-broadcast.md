# 전체 AI에 메시지를 브로드캐스트합니다.
# 사용법: /nco-broadcast <메시지>
# 예: /nco-broadcast "PR 리뷰 완료 — 다음 단계로 이동"

MSG="$ARGUMENTS"
if [ -z "$MSG" ]; then
  echo "[오류] 메시지를 입력하세요."
  exit 1
fi

curl -s -X POST http://localhost:6200/api/chat/messages \
  -H "Content-Type: application/json" \
  -d "{\"message\": $(echo "$MSG" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))'), \"broadcast\": true}" \
  | python3 -m json.tool 2>/dev/null || echo "[오류] NCO 서버 응답 없음."
