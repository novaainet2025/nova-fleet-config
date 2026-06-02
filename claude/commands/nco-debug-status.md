# Ollama 프록시 헬스 + 에러 통계를 출력합니다.

PROXY_URL="http://localhost:${PROXY_PORT:-4100}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  프록시 디버그 — 상태"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 프록시 헬스
P=$(curl -s -o /dev/null -w "%{http_code}" "${PROXY_URL}/health" 2>/dev/null)
[ "$P" = "200" ] && echo "  ✓ 프록시: 실행 중 (포트 ${PROXY_PORT:-4100})" \
                 || echo "  ✗ 프록시: 응답 없음 (HTTP ${P:-연결실패})"

# 디버그 통계
DEBUG=$(curl -s "${PROXY_URL}/debug/status" 2>/dev/null)
if [ -n "$DEBUG" ]; then
  echo ""
  echo "$DEBUG" | python3 -c "
import sys, json
d = json.load(sys.stdin)
p = d['proxy']
e = d['errors']
o = d.get('ollama', {})
print(f\"  업타임    : {p['uptime_s']}초\")
print(f\"  컨텍스트  : {p['max_ctx']}토큰 (입력 상한 {p['max_input_tokens']})\")
om = o.get('model','?')
ook = '✓' if o.get('reachable') else '✗'
print(f\"  Ollama    : {ook} {om}\")
print(f\"  에러 총계 : {e['total']}건\")
by = e.get('by_type', {})
if by:
    print('  에러 유형 :')
    for k, v2 in sorted(by.items(), key=lambda x: -x[1]):
        print(f'    {k}: {v2}회')
r = d.get('recovery', {})
if r.get('total', 0):
    print(f\"  복구 이력 : {r['total']}건\")
" 2>/dev/null
else
  echo "  (프록시 디버그 엔드포인트 미응답)"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
