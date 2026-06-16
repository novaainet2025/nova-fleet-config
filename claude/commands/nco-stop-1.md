# NCO 백엔드를 중지합니다.
# 사용법: /nco-stop-1

if ! curl -sf http://localhost:6200/health > /dev/null 2>&1; then
  echo "NCO가 이미 중지되어 있습니다."
  exit 0
fi

# PM2로 관리되는 경우
if pm2 list 2>/dev/null | grep -q "nco-backend.*online"; then
  pm2 stop nco-backend && echo "NCO 중지 완료 (PM2)"
  exit 0
fi

# 프로세스 직접 종료
PID=$(pgrep -f "neural-cli-orchestrator\|nco.*index" | head -1)
if [ -n "$PID" ]; then
  kill "$PID" && echo "NCO 종료 (PID: $PID)"
else
  echo "NCO 프로세스를 찾을 수 없습니다."
fi
