# 프록시 컨텍스트 한계를 재감지합니다 — 컨텍스트 초과 에러 발생 시 재보정.

PROXY_URL="http://localhost:${PROXY_PORT:-4100}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  프록시 디버그 — 컨텍스트 한계 재감지"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

RESULT=$(curl -s -X POST "${PROXY_URL}/debug/recover" \
  -H "Content-Type: application/json" \
  -d '{"action":"ctx_refresh"}' 2>/dev/null)

if [ -z "$RESULT" ]; then
  echo "  ✗ 프록시에 연결할 수 없습니다"
  exit 1
fi

echo "$RESULT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for s in d.get('steps', []):
    ok = s.get('ok', False)
    ctx = s.get('ctx', '?')
    changed = s.get('changed', False)
    if ok:
        ch = '(변경됨)' if changed else '(이미 최신)'
        print(f'  ✓ 컨텍스트 한계: {ctx} 토큰 {ch}')
    else:
        print(f\"  ✗ 재감지 실패: {s.get('error','')}\")
" 2>/dev/null
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
