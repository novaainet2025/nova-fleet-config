# NCO 설정 및 연결을 검증합니다.
# 사용법: /nco-verify

echo "=== NCO 설정 검증 ==="

echo ""
echo "[1/4] NCO 서버 헬스체크..."
if curl -sf http://localhost:6200/health > /dev/null 2>&1; then
  echo "  ✓ NCO 온라인 (:6200)"
  curl -s http://localhost:6200/health | python3 -m json.tool 2>/dev/null
else
  echo "  ✗ NCO 오프라인 — /nco-start 로 시작하세요"
fi

echo ""
echo "[2/4] vLLM 헬스체크..."
if curl -sf http://127.0.0.1:8000/health > /dev/null 2>&1; then
  echo "  ✓ vLLM 온라인 (:8000)"
else
  echo "  ✗ vLLM 오프라인"
fi

echo ""
echo "[3/4] vLLM 프록시 헬스체크..."
if pgrep -f "vllm-proxy" > /dev/null 2>&1; then
  echo "  ✓ 프록시 실행 중 (PID: $(pgrep -f vllm-proxy | head -1))"
else
  echo "  ✗ 프록시 중지됨"
fi

echo ""
echo "[4/4] AI 프로바이더 목록..."
curl -s http://localhost:6200/api/ai-providers 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "  (NCO 오프라인)"
