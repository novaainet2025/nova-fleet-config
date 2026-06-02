# Ollama 프록시 에러 카운터와 이력을 초기화합니다.

PROXY_URL="http://localhost:${PROXY_PORT:-4100}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  프록시 디버그 — 에러 초기화"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

RESULT=$(curl -s -X POST "${PROXY_URL}/debug/recover" \
  -H "Content-Type: application/json" \
  -d '{"action":"error_clear"}' 2>/dev/null)

if [ -z "$RESULT" ]; then
  echo "  ✗ 프록시에 연결할 수 없습니다 (${PROXY_URL})"
  exit 1
fi

echo "$RESULT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
ok = d.get('success', False)
for s in d.get('steps', []):
    n = s.get('cleared', 0)
    if s.get('ok'):
        print(f'  ✓ {n}개 에러 기록 초기화 완료')
    else:
        print(f\"  ✗ 초기화 실패: {s.get('error','')}\")
" 2>/dev/null
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
