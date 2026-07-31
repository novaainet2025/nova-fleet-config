# 파일 백업 목록과 검증 게이트 결과를 조회합니다.

echo "=== File Backups ==="
curl -s http://localhost:6200/api/safety/backups | python3 -m json.tool

# $ARGUMENTS가 있으면 해당 Task의 검증 결과도 표시합니다.
# 형식: /nco-safety [taskId]
if [ -n "$ARGUMENTS" ]; then
  echo ""
  echo "=== Validation Gates: $ARGUMENTS ==="
  # /api/safety/gates 는 서버에 존재하지 않는 라우트였다(항상 404).
  # 실제 구현된 경로는 /api/safety/verifications/:taskId 이다.
  curl -s "http://localhost:6200/api/safety/verifications/$ARGUMENTS" | python3 -m json.tool
fi
