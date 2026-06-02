# NCO 시스템 상태를 확인합니다.
echo "=== NCO Health ==="
HEALTH=$(curl -s http://localhost:6200/health)
if [ -z "$HEALTH" ]; then
  echo "NCO 서버 오프라인 (포트 6200 응답 없음)"
else
  echo "$HEALTH" | python3 -m json.tool 2>/dev/null || echo "$HEALTH"
fi

echo ""
echo "=== AI Providers ==="
STATUS=$(curl -s http://localhost:6200/api/ai-providers/status)
if [ -z "$STATUS" ]; then
  echo "(응답 없음)"
else
  echo "$STATUS" | python3 -m json.tool 2>/dev/null || echo "$STATUS"
fi
