# MLX 로컬 서버를 관리합니다 (시작/중지/상태/테스트/설정 등). macOS Apple Silicon 전용.

# 사용법:
#   /nco-mlx                          — 현재 상태 확인 (기본)
#   /nco-mlx status                   — 상세 상태 + 메모리 사용량
#   /nco-mlx start                    — MLX 서버 시작 (pm2)
#   /nco-mlx stop                     — MLX 서버 중지
#   /nco-mlx restart                  — 재시작
#   /nco-mlx ensure                   — 실행 중이면 유지, 아니면 자동 시작
#   /nco-mlx logs [줄수]              — 서버 로그 출력 (기본 50줄)
#   /nco-mlx models                   — 로드된 모델 목록
#   /nco-mlx test                     — 추론 동작 테스트
#   /nco-mlx chat <프롬프트>          — 직접 채팅 (단발성 추론)
#   /nco-mlx config                   — 현재 MLX 설정 출력
#   /nco-mlx enable                   — NCO 프로바이더 활성화
#   /nco-mlx disable                  — NCO 프로바이더 비활성화
#   /nco-mlx proxy start             — Anthropic-MLX 프록시 시작 (port 4100)
#   /nco-mlx proxy stop              — 프록시 중지
#   /nco-mlx proxy status            — 프록시 상태 확인

# 예:
#   /nco-mlx start
#   /nco-mlx chat "한국어로 안녕하세요를 영어로 번역해줘"
#   /nco-mlx logs 100

PM2_NAME="mlx-server"
PORT=8000
MLX_API="http://localhost:${PORT}/v1"
MODEL_PATH="{{HOME}}/project/LM-models/mlx/gemma-4-26b-a4b-it-4bit"
MLX_BIN="{{HOME}}/.local/bin/mlx_lm.server"
CONFIG_FILE="{{HOME}}/project/nco/config/ai-providers.json"

ACTION=$(echo $ARGUMENTS | cut -d' ' -f1)
ARG2=$(echo $ARGUMENTS | cut -d' ' -f2)
REST=$(echo $ARGUMENTS | cut -d' ' -f2-)

[ -z "$ACTION" ] && ACTION="status"

case "$ACTION" in
  status)
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  MLX 서버 상태"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    PM2_LINE=$(pm2 jlist 2>/dev/null | python3 -c "
import sys, json
try:
  apps = json.load(sys.stdin)
  for a in apps:
    if a['name'] == '$PM2_NAME':
      print(a['pid'], a['pm2_env']['status'], a['monit']['memory'])
      break
except: pass" 2>/dev/null)
    if [ -n "$PM2_LINE" ]; then
      PID=$(echo "$PM2_LINE" | awk '{print $1}')
      ST=$(echo "$PM2_LINE" | awk '{print $2}')
      MEM=$(echo "$PM2_LINE" | awk '{print $3}')
      MEM_GB=$(awk "BEGIN{printf \"%.2f\", $MEM/1073741824}")
      HEALTH=$(curl -s -o /dev/null -w "%{http_code}" "${MLX_API}/models" 2>/dev/null)
      echo "  ● PM2 상태  : $ST (PID: $PID)"
      echo "  ✓ 헬스      : HTTP $HEALTH"
      echo "  메모리      : ${MEM_GB} GB (unified)"
    else
      echo "  ○ 상태      : 중지됨 (pm2에 등록 안됨)"
    fi
    SYS_MEM=$(vm_stat | awk '/Pages free/{f=$3} /Pages active/{a=$3} /Pages wired/{w=$4} END{printf "%.1f / %.1f GB free", f*4096/1073741824, (f+a+w)*4096/1073741824}')
    echo "  시스템 메모리: $SYS_MEM"
    echo "  엔드포인트  : ${MLX_API}"
    echo "  모델 경로   : $MODEL_PATH"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    ;;

  start)
    echo "MLX 서버 시작 중..."
    pm2 describe $PM2_NAME >/dev/null 2>&1 && pm2 start $PM2_NAME 2>&1 | tail -3 \
      || pm2 start "$MLX_BIN" --name $PM2_NAME --interpreter none --max-memory-restart 30G \
           -- --model "$MODEL_PATH" --port $PORT --host 127.0.0.1 2>&1 | tail -3
    ;;

  stop)
    echo "MLX 서버 중지 중..."
    pm2 stop $PM2_NAME 2>&1 | tail -3
    ;;

  restart)
    echo "MLX 서버 재시작 중..."
    pm2 restart $PM2_NAME 2>&1 | tail -3
    ;;

  ensure)
    if pm2 jlist 2>/dev/null | grep -q "\"name\":\"$PM2_NAME\"" && \
       curl -sf "${MLX_API}/models" >/dev/null 2>&1; then
      echo "✓ MLX 서버 정상 실행 중"
    else
      echo "MLX 서버 시작..."
      pm2 describe $PM2_NAME >/dev/null 2>&1 && pm2 restart $PM2_NAME 2>&1 | tail -3 \
        || pm2 start "$MLX_BIN" --name $PM2_NAME --interpreter none --max-memory-restart 30G \
             -- --model "$MODEL_PATH" --port $PORT --host 127.0.0.1 2>&1 | tail -3
    fi
    ;;

  logs)
    LINES=${ARG2:-50}
    echo "━━━ MLX 로그 (최근 ${LINES}줄) ━━━"
    pm2 logs $PM2_NAME --lines $LINES --nostream 2>&1 | tail -n $((LINES+5))
    ;;

  models)
    echo "━━━ 로드된 모델 ━━━"
    curl -s "${MLX_API}/models" 2>/dev/null | python3 -c "
import sys, json
try:
  d = json.load(sys.stdin)
  for m in d.get('data', []):
    print(f'  • {m[\"id\"]}')
except:
  print('  MLX 서버 미실행. /nco-mlx start')"
    ;;

  test)
    echo "━━━ MLX 추론 테스트 ━━━"
    MODEL=$(curl -s "${MLX_API}/models" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null)
    if [ -z "$MODEL" ]; then
      echo "  ✗ 서버 미실행. /nco-mlx start 후 다시 시도하세요."
      exit 1
    fi
    echo "  모델: $MODEL"
    echo "  프롬프트: '안녕하세요, 자기소개를 해주세요.' (한 문장)"
    echo ""
    curl -s -X POST "${MLX_API}/chat/completions" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"안녕하세요, 자기소개를 한 문장으로.\"}],\"max_tokens\":100,\"temperature\":0.7}" \
      2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
if 'choices' in d:
    msg = d['choices'][0]['message']
    out = msg.get('content') or msg.get('reasoning') or '(empty)'
    print('  응답:', out.strip())
    u = d.get('usage', {})
    print(f'  토큰: 입력 {u.get(\"prompt_tokens\",0)} + 출력 {u.get(\"completion_tokens\",0)} = 총 {u.get(\"total_tokens\",0)}')
else:
    print('  오류:', json.dumps(d, ensure_ascii=False))"
    ;;

  chat)
    PROMPT="$REST"
    if [ -z "$PROMPT" ]; then
      echo "사용법: /nco-mlx chat <프롬프트>"
      exit 1
    fi
    MODEL=$(curl -s "${MLX_API}/models" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null)
    if [ -z "$MODEL" ]; then
      echo "  ✗ 서버 미실행. /nco-mlx start 후 다시 시도하세요."
      exit 1
    fi
    echo "━━━ MLX 채팅 ━━━"
    echo "  모델: $MODEL"
    echo "  프롬프트: $PROMPT"
    echo ""
    ESCAPED=$(echo "$PROMPT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))")
    curl -s -X POST "${MLX_API}/chat/completions" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":$ESCAPED}],\"max_tokens\":512,\"temperature\":0.7}" \
      2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
if 'choices' in d:
    msg = d['choices'][0]['message']
    out = msg.get('content') or msg.get('reasoning') or '(empty)'
    print(out.strip())
    print()
    u = d.get('usage', {})
    print(f'[토큰: 입력 {u.get(\"prompt_tokens\",0)} + 출력 {u.get(\"completion_tokens\",0)}]')
else:
    print('오류:', json.dumps(d, ensure_ascii=False))"
    ;;

  config)
    echo "━━━ MLX 설정 ━━━"
    python3 -c "
import json
with open('$CONFIG_FILE') as f:
    d = json.load(f)
for p in d.get('providers', []):
    if p['id'] == 'mlx':
        print(f'  ID        : {p[\"id\"]}')
        print(f'  이름      : {p[\"name\"]}')
        print(f'  활성화    : {\"예\" if p.get(\"enabled\") else \"아니오\"}')
        print(f'  역할      : {p[\"role\"]}')
        print(f'  점수      : {p[\"score\"]}점')
        print(f'  비용      : {p[\"cost\"]}')
        print(f'  엔드포인트: {p[\"endpoint\"]}')
        print(f'  모델      : {p[\"model\"]}')
        ms = p.get('modelSpec', {})
        print(f'  모델 스펙  :')
        print(f'    이름    : {ms.get(\"name\",\"-\")}')
        print(f'    파라미터: {ms.get(\"parameters\",\"-\")}')
        print(f'    양자화  : {ms.get(\"quantization\",\"-\")}')
        print(f'    GPU     : {ms.get(\"gpu\",\"-\")}')
        print(f'    메모리  : {ms.get(\"vram\",\"-\")}')
        print(f'    최대길이: {ms.get(\"maxModelLen\",\"-\")} 토큰')
        print(f'  동시 요청 : {p.get(\"concurrency\",1)}')
        print(f'  RPM 한도  : {p.get(\"rateLimitRpm\",5)}')
        caps = p.get('capabilities', [])
        print(f'  기능      : {\" | \".join(caps)}')
" 2>/dev/null || echo "  설정 파일을 읽을 수 없습니다: $CONFIG_FILE"
    ;;

  enable)
    python3 -c "
import json
with open('$CONFIG_FILE', 'r') as f:
    d = json.load(f)
for p in d.get('providers', []):
    if p['id'] == 'mlx':
        p['enabled'] = True
with open('$CONFIG_FILE', 'w') as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
print('✓ MLX 프로바이더 활성화됨')
print('  NCO 서버 재시작 필요: /nco-start')
" 2>/dev/null || echo "설정 파일 변경 실패"
    ;;

  disable)
    python3 -c "
import json
with open('$CONFIG_FILE', 'r') as f:
    d = json.load(f)
for p in d.get('providers', []):
    if p['id'] == 'mlx':
        p['enabled'] = False
with open('$CONFIG_FILE', 'w') as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
print('○ MLX 프로바이더 비활성화됨')
print('  NCO 서버 재시작 필요: /nco-start')
" 2>/dev/null || echo "설정 파일 변경 실패"
    ;;

  proxy)
    SUB=$ARG2
    PROXY_PORT=4100
    PROXY_SCRIPT="{{HOME}}/project/nco/cli-installs/anthropic-mlx-proxy.py"
    PROXY_LOG="/tmp/anthropic-mlx-proxy.log"
    case "$SUB" in
      start)
        if curl -sf "http://localhost:${PROXY_PORT}/health" >/dev/null 2>&1; then
          PID=$(pgrep -f "anthropic-mlx-proxy" | head -1)
          echo "✓ 프록시 이미 실행 중 (port ${PROXY_PORT}, PID: ${PID})"
        else
          nohup python3 "$PROXY_SCRIPT" $PROXY_PORT >> "$PROXY_LOG" 2>&1 &
          sleep 2
          curl -sf "http://localhost:${PROXY_PORT}/health" >/dev/null 2>&1             && echo "✓ 프록시 시작됨 (port ${PROXY_PORT})"             || echo "✗ 프록시 시작 실패 (로그: $PROXY_LOG)"
        fi
        echo "  사용: ANTHROPIC_BASE_URL=http://localhost:${PROXY_PORT} ANTHROPIC_API_KEY=dummy claude"
        ;;
      stop)
        pkill -f "anthropic-mlx-proxy.py" 2>/dev/null && echo "✓ 프록시 중지됨" || echo "실행 중인 프록시 없음"
        ;;
      status|"")
        if curl -sf "http://localhost:${PROXY_PORT}/health" >/dev/null 2>&1; then
          PID=$(pgrep -f "anthropic-mlx-proxy" | head -1)
          echo "● 프록시 실행 중 (port ${PROXY_PORT}, PID: ${PID})"
          curl -s "http://localhost:${PROXY_PORT}/health" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'  mlx_base: {d.get(\"mlx_base\",\"-\")}')" 2>/dev/null
        else
          echo "○ 프록시 중지됨"
          echo "  시작: /nco-mlx proxy start"
        fi
        ;;
      *)
        echo "사용법: /nco-mlx proxy {start|stop|status}"
        ;;
    esac
    ;;


  *)
    echo "알 수 없는 명령: $ACTION"
    echo ""
    echo "사용 가능한 명령:"
    echo "  status, start, stop, restart, ensure"
    echo "  logs [줄수], models, test, chat <프롬프트>"
    echo "  config, enable, disable"
    ;;
esac
