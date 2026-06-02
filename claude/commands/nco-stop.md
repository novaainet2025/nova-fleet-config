# NCO 백엔드를 중지합니다.
# 사용법: /nco-stop

if ! curl -sf http://localhost:6200/health > /dev/null 2>&1; then
  echo "NCO가 이미 중지되어 있습니다."
  exit 0
fi

curl -s -X POST http://localhost:6200/api/system/stop \
  -H "Content-Type: application/json" \
  | python3 -m json.tool 2>/dev/null

# 프로세스 직접 종료 (API 응답 없을 시 폴백)
sleep 1
if curl -sf http://localhost:6200/health > /dev/null 2>&1; then
  PID=$(pgrep -f "neural-cli-orchestrator\|nco.*index" | head -1)
  if [ -n "$PID" ]; then
    kill "$PID" && echo "NCO 종료 (PID: $PID)"
  fi
else
  echo "NCO 중지 완료"
fi
