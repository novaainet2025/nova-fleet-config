---
description: NCO 백엔드를 중지합니다.
dangerous: true
---
# NCO 백엔드를 중지합니다.
# 사용법: /nco-stop
#
# 2026-07-29 수정: 기존 구현은 POST /api/system/stop 을 호출했으나 그 라우트는
# 서버에 존재하지 않는다. dashboard-compat 의 catch-all 이 HTTP 200 +
# {"data":[],"message":"... pending implementation"} 을 돌려줘 성공처럼 보이지만
# 실제로는 아무 일도 일어나지 않았다. 또 폴백의 raw kill 은 PM2 가 감독 중인
# 프로세스를 죽여봐야 즉시 재기동되므로 중지가 되지 않는다.
# 상주 배포 원칙(PM2 단일 감독)에 맞춰 pm2 stop 을 우선 경로로 쓴다.

if ! curl -sf http://localhost:6200/health > /dev/null 2>&1; then
  echo "NCO가 이미 중지되어 있습니다."
  exit 0
fi

# PM2로 관리되는 경우 — 반드시 PM2를 경유해야 재기동 루프가 생기지 않는다
if pm2 list 2>/dev/null | grep -q "nco-backend.*online"; then
  pm2 stop nco-backend && echo "NCO 중지 완료 (PM2)"
  exit 0
fi

# PM2 미관리 시에만 프로세스 직접 종료
PID=$(pgrep -f "neural-cli-orchestrator\|nco.*index" | head -1)
if [ -n "$PID" ]; then
  kill "$PID" && echo "NCO 종료 (PID: $PID)"
else
  echo "NCO 프로세스를 찾을 수 없습니다."
fi
