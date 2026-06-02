# Ollama 프록시 모델 캐시를 강제 갱신합니다 — 모델 전환 후 인식 불일치 해결.

PROXY_URL="http://localhost:${PROXY_PORT:-4100}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  프록시 디버그 — 모델 캐시 갱신"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

RESULT=$(curl -s -X POST "${PROXY_URL}/debug/recover" \
  -H "Content-Type: application/json" \
  -d '{"action":"model_refresh"}' 2>/dev/null)

if [ -z "$RESULT" ]; then
  echo "  ✗ 프록시에 연결할 수 없습니다"
  exit 1
fi

echo "$RESULT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for s in d.get('steps', []):
    ok = s.get('ok', False)
    model = s.get('model', 'unknown')
    print('  ' + ('✓ 갱신 완료 — 현재 모델: ' + model if ok else '✗ 갱신 실패: ' + s.get('error','')))
" 2>/dev/null
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
