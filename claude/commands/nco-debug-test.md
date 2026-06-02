# Ollama 프록시 추론 테스트 — 단순 메시지를 전송해 end-to-end 동작을 확인합니다.

PROXY_URL="http://localhost:${PROXY_PORT:-4100}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  프록시 디버그 — 추론 테스트"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 프록시 헬스 먼저 확인
P=$(curl -s -o /dev/null -w "%{http_code}" "${PROXY_URL}/health" 2>/dev/null)
if [ "$P" != "200" ]; then
  echo "  ✗ 프록시 미응답 — security-kb/anthropic-ollama-proxy.py 를 먼저 시작하세요"
  exit 1
fi

echo "  ◉ 요청 전송 중..."
START=$(date +%s%N 2>/dev/null || date +%s)

RESP=$(curl -s --max-time 60 -X POST "${PROXY_URL}/v1/messages" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -H "x-api-key: dummy" \
  -d '{"model":"claude-haiku-4-5-20251001","max_tokens":60,"messages":[{"role":"user","content":"안녕하세요. \"테스트 성공\"이라고만 답해주세요."}]}' \
  2>/dev/null)

END=$(date +%s%N 2>/dev/null || date +%s)

echo "$RESP" | python3 -c "
import sys, json, time
try:
    d = json.load(sys.stdin)
    if 'content' in d:
        text = d['content'][0].get('text','').strip()
        in_t = d.get('usage',{}).get('input_tokens','?')
        out_t = d.get('usage',{}).get('output_tokens','?')
        model = d.get('model','?')
        print(f'  ✓ 응답: {text[:100]}')
        print(f'  ◉ 모델: {model}')
        print(f'  ◉ 토큰: 입력 {in_t} / 출력 {out_t}')
    elif 'error' in d:
        print(f\"  ✗ 에러: {d['error'].get('message','')}\")
    else:
        print(f'  ? 응답: {str(d)[:200]}')
except Exception as e:
    raw = sys.stdin.read() if not sys.stdin.closed else ''
    print(f'  ✗ 파싱 실패: {e}')
" 2>/dev/null || echo "  ✗ 응답 없음 또는 파싱 오류"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
