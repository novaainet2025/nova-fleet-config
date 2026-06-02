# Ollama 프록시 최근 에러 목록을 출력합니다 (타입별 분류 포함).

PROXY_URL="http://localhost:${PROXY_PORT:-4100}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  프록시 디버그 — 최근 에러"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

DEBUG=$(curl -s "${PROXY_URL}/debug/status" 2>/dev/null)
if [ -z "$DEBUG" ]; then
  echo "  ✗ 프록시에 연결할 수 없습니다 (${PROXY_URL})"
  echo "    프록시(security-kb/anthropic-ollama-proxy.py)를 먼저 시작하세요."
  exit 1
fi

echo "$DEBUG" | python3 -c "
import sys, json
d = json.load(sys.stdin)
e = d['errors']
print(f\"  총 에러: {e['total']}건\")

by = e.get('by_type', {})
if by:
    print()
    print('  유형별 집계:')
    for k, v in sorted(by.items(), key=lambda x: -x[1]):
        icon = {'context_overflow':'↔','connection_refused':'⚡','cuda_oom':'💾',
                'timeout':'⏱','http_5xx':'🔴','http_4xx':'🟡','json_parse':'⚠'}.get(k,'◉')
        print(f'    {icon} {k}: {v}회')

recent = e.get('recent', [])
if recent:
    print()
    print(f'  최근 {len(recent)}개 에러:')
    for err in recent:
        mark = '✓' if err.get('recovered') else '✗'
        print(f\"    [{err['time']}] {mark} [{err['type']}]\")
        print(f\"              {err['msg']}\")
else:
    print()
    print('  (최근 에러 없음)')
" 2>/dev/null
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
