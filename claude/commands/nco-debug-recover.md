# Ollama 프록시 자가 복구를 실행합니다 — 모델 캐시 갱신 + 헬스체크 + 컨텍스트 재감지.

# 사용법: /nco-debug-recover [auto|model_refresh|health_check|ctx_refresh|error_clear]

PROXY_URL="http://localhost:${PROXY_PORT:-4100}"
ACTION="${1:-auto}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  프록시 디버그 — 자가 복구 (액션: ${ACTION})"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

RESULT=$(curl -s -X POST "${PROXY_URL}/debug/recover" \
  -H "Content-Type: application/json" \
  -d "{\"action\":\"${ACTION}\"}" 2>/dev/null)

if [ -z "$RESULT" ]; then
  echo "  ✗ 프록시에 연결할 수 없습니다 (${PROXY_URL})"
  echo "    프록시(security-kb/anthropic-ollama-proxy.py)를 먼저 시작하세요."
  exit 1
fi

echo "$RESULT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
ok = d.get('success', False)
print('  결과:', '✓ 성공' if ok else '✗ 실패')
print()
for s in d.get('steps', []):
    step = s.get('step', '?')
    s_ok = s.get('ok', False)
    mark = '✓' if s_ok else '✗'
    detail = ''
    if 'model' in s:     detail = f\" → 모델: {s['model']}\"
    elif 'ctx' in s:     detail = f\" → 컨텍스트: {s['ctx']} 토큰 (변경={s.get('changed',False)})\"
    elif 'cleared' in s: detail = f\" → {s['cleared']}개 에러 초기화\"
    elif 'status' in s:  detail = f\" → HTTP {s['status']}\"
    elif 'error' in s:   detail = f\" → 오류: {s['error']}\"
    print(f'  {mark} {step}{detail}')
" 2>/dev/null

echo ""
echo "  사용 가능한 액션:"
echo "    auto           — 모두 실행 (model_refresh + health_check + ctx_refresh)"
echo "    model_refresh  — 모델 캐시 강제 갱신"
echo "    health_check   — 프록시 헬스 확인"
echo "    ctx_refresh    — 컨텍스트 한계 재감지"
echo "    error_clear    — 에러 카운터 초기화"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
