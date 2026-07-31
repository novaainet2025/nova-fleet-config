# NCO 백엔드를 시작합니다.

# 이미 실행 중이면 재시작하지 않음
if curl -sf http://localhost:6200/health > /dev/null 2>&1; then
  echo "NCO already running on :6200"
  curl -s http://localhost:6200/health | python3 -m json.tool
  exit 0
fi

NCO_DIR="${NCO_PROJECT_DIR:-$HOME/project/nco}"
if [ ! -d "$NCO_DIR" ]; then
  echo "NCO 프로젝트를 찾을 수 없습니다: $NCO_DIR"
  echo "NCO_PROJECT_DIR로 실제 경로를 지정하세요."
  exit 1
fi

if command -v pm2 >/dev/null 2>&1 && pm2 describe nco-backend >/dev/null 2>&1; then
  pm2 start nco-backend >/dev/null
  echo "NCO Backend starting through PM2"
else
  cd "$NCO_DIR" || exit 1
  node dist/index.js > /tmp/nco-backend.log 2>&1 &
  echo "NCO Backend starting on :6200 + :6201 (PID: $!)"
fi
sleep 3
if ! curl -sf http://localhost:6200/health | python3 -m json.tool; then
  echo "NCO가 3초 안에 준비되지 않았습니다. 로그/PM2 상태를 확인하세요."
  exit 1
fi
