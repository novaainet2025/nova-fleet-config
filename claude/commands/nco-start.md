# NCO 백엔드를 시작합니다.

# 이미 실행 중이면 재시작하지 않음
if curl -sf http://localhost:6200/health > /dev/null 2>&1; then
  echo "NCO already running on :6200"
  curl -s http://localhost:6200/health | python3 -m json.tool
  exit 0
fi

cd /home/nova/projects/neural-cli-orchestrator && npx tsx src/index.ts &
echo "NCO Backend starting on :6200 + :6201 (PID: $!)"
sleep 3
curl -s http://localhost:6200/health | python3 -m json.tool
