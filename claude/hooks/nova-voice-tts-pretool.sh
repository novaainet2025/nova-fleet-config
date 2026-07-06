#!/bin/bash
# nova-voice-tts-pretool.sh — PreToolUse: "XXX 작업을 시작합니다"
SETTINGS_FILE="$HOME/Library/Application Support/nova-voice/nova-settings.json"
DEBOUNCE_FILE="/tmp/nova-tts-pretool-ts"
LOG="/tmp/nova-tts-hook.log"

# nova-voice PTY 세션 전용 게이트 — 앱이 심는 NOVA_VOICE_SESSION=1 없으면 무음
[ "${NOVA_VOICE_SESSION:-}" != "1" ] && exit 0

NOW=$(date +%s)
LAST=$(cat "$DEBOUNCE_FILE" 2>/dev/null || echo 0)
[ $(( NOW - LAST )) -lt 3 ] && exit 0

TTS_CONFIG=$(python3 -c "
import json
Q={'Ryan':'ryan','Chelsie':'sohee','Vivian':'vivian','Aiden':'aiden','Ethan':'uncle_fu','Serena':'serena','Eric':'eric','Dylan':'dylan'}
K={'Ryan':'am_adam','Chelsie':'af_bella','Vivian':'af_heart','Aiden':'am_adam','Ethan':'bm_george','Serena':'bf_emma','Eric':'am_adam','Dylan':'bm_george'}
try:
    d=json.load(open('$SETTINGS_FILE'))
    m,v=d.get('ttsModel','all_tts'),d.get('mlxVoice','Serena')
except: m,v='all_tts','Serena'
if m=='all_tts':
    adapter=d.get('allTtsAdapter','edge_tts') if 'd' in dir() else 'edge_tts'
    voice=d.get('allTtsVoice','ko-KR-SunHiNeural') if 'd' in dir() else 'ko-KR-SunHiNeural'
    print(f'http://localhost:7861|all_tts|{adapter}|{voice}')
elif m=='qwen3': print(f'http://localhost:7860|qwen3|{Q.get(v,\"serena\")}')
elif m in('mlx','mlx_ko'): print('http://localhost:8800|openai|')
elif m=='mlx_en': print(f'http://localhost:8801|openai|{K.get(v,\"bf_emma\")}')
else: print(f'http://localhost:7861|all_tts|edge_tts|ko-KR-SunHiNeural')
" 2>/dev/null || echo "http://localhost:7861|all_tts|edge_tts|ko-KR-SunHiNeural")
TTS_API=$(echo "$TTS_CONFIG"|cut -d'|' -f1)
TTS_MODE=$(echo "$TTS_CONFIG"|cut -d'|' -f2)
TTS_VOICE=$(echo "$TTS_CONFIG"|cut -d'|' -f3)
# all_tts: field3=adapter, field4=voice
ALL_TTS_ADAPTER=""
ALL_TTS_VOICE=""
if [ "$TTS_MODE" = "all_tts" ]; then
    ALL_TTS_ADAPTER="$TTS_VOICE"
    ALL_TTS_VOICE=$(echo "$TTS_CONFIG"|cut -d'|' -f4)
fi

TMP_JSON=$(mktemp /tmp/nova-hook-XXXXXX)
cat > "$TMP_JSON"

MSG=$(python3 - "$TMP_JSON" 2>/dev/null << 'PYEOF2'
import json, sys, re, os

try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except: sys.exit(0)

tool = data.get('tool_name','')
inp  = data.get('tool_input',{}) or {}

def project_name(path_or_cmd):
    """경로 또는 명령에서 프로젝트명 추출"""
    text = str(path_or_cmd)
    # 알려진 프로젝트 매핑
    proj_map = [
        (r'nova-voice', '노바 보이스'),
        (r'claude/hooks|\.claude/hooks', '클로드 훅'),
        (r'\.claude/settings', '클로드 설정'),
        (r'homebrew|/opt/', '시스템'),
        (r'venv|\.venv|site-packages', '파이썬 환경'),
    ]
    for pattern, name in proj_map:
        if re.search(pattern, text, re.I):
            return name
    # project/ 하위 디렉토리 추출
    m = re.search(r'/project/([^/\s]+)', text)
    if m: return m.group(1)
    # src/ 상위 디렉토리 추출
    m = re.search(r'/([^/]+)/src/', text)
    if m: return m.group(1)
    return ''

def src_area(path):
    """src 하위 영역 추출"""
    area_map = [
        (r'/main/tts', 'TTS 엔진'),
        (r'/main/ipc', 'IPC 핸들러'),
        (r'/main/pipeline', '파이프라인'),
        (r'/main/shortcuts', '단축키'),
        (r'/main/index', '메인 프로세스'),
        (r'/renderer/components/settings', '설정 UI'),
        (r'/renderer/components/unified', '메인 패널'),
        (r'/renderer/components/home', '홈 화면'),
        (r'/renderer/hooks', '렌더러 훅'),
        (r'/renderer/stores', '상태 저장소'),
        (r'/preload', '프리로드'),
        (r'/renderer', '렌더러'),
        (r'/main', '메인 프로세스'),
        (r'hooks/', '훅 스크립트'),
    ]
    for pattern, name in area_map:
        if re.search(pattern, path, re.I):
            return name
    return ''

if tool == 'Bash':
    cmd = str(inp.get('command','')).strip()
    cl = cmd.lower()
    if re.search(r'grep|find|ls\b|cat\b|head\b|tail\b|echo\b|curl.*localhost|afplay|nova-tts|ps aux', cl):
        sys.exit(0)

    proj = project_name(cmd)
    proj_prefix = f'{proj} ' if proj else ''

    if re.search(r'npm run build|bun run build|yarn build|electron-vite build', cl):
        msg = f'{proj_prefix}프로젝트 빌드를 시작합니다'
    elif re.search(r'tsc\b|--noemit', cl):
        msg = f'{proj_prefix}타입 검사를 시작합니다'
    elif re.search(r'npm install|pip install|yarn add|bun add|brew install', cl):
        m = re.search(r'(?:install|add)\s+([\w@/\-\.]+)', cmd)
        pkg = m.group(1)[:20] if m else ''
        msg = f'{pkg} 패키지 설치를 시작합니다' if pkg else f'{proj_prefix}패키지 설치를 시작합니다'
    elif re.search(r'npm run dev|bun dev|yarn dev|electron-vite dev', cl):
        msg = f'{proj_prefix}개발 서버를 시작합니다'
    elif re.search(r'pytest|jest|vitest|npm test|bun test', cl):
        msg = f'{proj_prefix}테스트를 시작합니다'
    elif re.search(r'git push', cl):
        msg = f'{proj_prefix}원격 저장소에 푸시합니다'
    elif re.search(r'<<\s*[\'"]?\w{3,}[\'"]?', cmd) or re.search(r'cat\s*>', cmd):
        m2 = re.search(r'cat\s*[>]+\s*["\']?([\S]+)', cmd)
        if m2:
            p = project_name(m2.group(1))
            a = src_area(m2.group(1))
            fn = os.path.basename(m2.group(1))[:20]
            loc = f'{p} {a}' if p and a else (p or a or fn)
            msg = f'{loc} 파일을 작성합니다'
        else:
            msg = f'{proj_prefix}파일을 작성합니다'
    else:
        sys.exit(0)

elif tool == 'Agent':
    desc = str(inp.get('description','') or inp.get('prompt',''))[:40]
    msg = f'에이전트 작업을 시작합니다: {desc}' if desc else '에이전트 작업을 시작합니다'

elif tool == 'Write':
    path = str(inp.get('file_path',''))
    proj = project_name(path)
    area = src_area(path)
    fn = os.path.basename(path)[:20]
    loc = f'{proj} {area}'.strip() if proj or area else fn
    msg = f'{loc} 파일을 작성합니다'

else:
    sys.exit(0)

print(msg[:90])
PYEOF2
)

rm -f "$TMP_JSON"
[ -z "$MSG" ] && exit 0
echo "$NOW" > "$DEBOUNCE_FILE"
echo "[$(date +%H:%M:%S)] pre: $MSG" >> "$LOG"

(
    TMP_WAV="/tmp/nova-tts-pre-$$.wav"
    if [ "$TTS_MODE" = "all_tts" ]; then
        # all-tts Hub SSE streaming
        HEALTH=$(curl -s --connect-timeout 2 --max-time 3 "${TTS_API}/health" 2>/dev/null || echo "")
        echo "$HEALTH" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('status')=='ok'" 2>/dev/null || exit 0
        TMP_MP3="${TMP_WAV%.wav}.mp3"
        python3 -c "
import urllib.request, urllib.parse, base64, sys
text, adapter, voice, out, api = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
params = urllib.parse.urlencode({'text': text, 'adapter': adapter, 'voice': voice, 'speaker': voice, 'speed': '1.0', 'format': 'mp3'})
url = api + '/api/stream?' + params
chunks = []
try:
    with urllib.request.urlopen(url, timeout=30) as r:
        buf = b''
        for line in r:
            buf += line
            while b'\\n\\n' in buf:
                msg, buf = buf.split(b'\\n\\n', 1)
                lines = msg.decode('utf-8', errors='replace').strip().split('\\n')
                ev, data = '', ''
                for l in lines:
                    if l.startswith('event:'): ev = l[6:].strip()
                    elif l.startswith('data:'): data = l[5:].strip()
                if ev == 'audio' and data:
                    chunks.append(base64.b64decode(data))
                elif ev == 'done': break
    if chunks:
        with open(out, 'wb') as f:
            for c in chunks: f.write(c)
except: pass
" "$MSG" "$ALL_TTS_ADAPTER" "$ALL_TTS_VOICE" "$TMP_MP3" "$TTS_API" 2>/dev/null
        [ -s "$TMP_MP3" ] && afplay "$TMP_MP3" 2>/dev/null
        rm -f "$TMP_MP3"
        exit 0
    elif [ "$TTS_MODE" = "qwen3" ]; then
        ! curl -s --connect-timeout 1 --max-time 2 "${TTS_API}/health" > /dev/null 2>&1 && exit 0
        PAYLOAD=$(python3 -c "import json,sys; print(json.dumps({'text':sys.argv[1],'speaker':sys.argv[2],'lang':'ko'}))" "$MSG" "$TTS_VOICE" 2>/dev/null)
        AUDIO_JSON=$(curl -s --connect-timeout 3 --max-time 15 -X POST -H "Content-Type: application/json" -d "$PAYLOAD" "${TTS_API}/api/voices/qwen3-tts/tts" 2>/dev/null)
        AUDIO_URL=$(echo "$AUDIO_JSON" | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('url',''))
except: pass" 2>/dev/null)
        [ -z "$AUDIO_URL" ] && exit 0
        HTTP_CODE=$(curl -s --connect-timeout 3 --max-time 15 -w "%{http_code}" -o "$TMP_WAV" "${TTS_API}${AUDIO_URL}" 2>/dev/null)
    else
        ROUTE_MODEL=$(curl -s --max-time 2 "${TTS_API}/v1/models" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'] if d.get('data') else '')" 2>/dev/null || echo "")
        [ -z "$ROUTE_MODEL" ] && exit 0
        TMP_PAY="/tmp/nova-pre-pay-$$.json"
        python3 -c "import json,sys; v=sys.argv[3]; p={'model':sys.argv[1],'input':sys.argv[2],'response_format':'wav'}; p.update({'voice':v} if v else {}); open(sys.argv[4],'w').write(json.dumps(p))" "$ROUTE_MODEL" "$MSG" "$TTS_VOICE" "$TMP_PAY" 2>/dev/null
        HTTP_CODE=$(curl -s --connect-timeout 3 --max-time 15 -w "%{http_code}" -o "$TMP_WAV" -X POST -H "Content-Type: application/json" -d "@$TMP_PAY" "${TTS_API}/v1/audio/speech" 2>/dev/null)
        rm -f "$TMP_PAY"
    fi
    [ "$HTTP_CODE" = "200" ] && [ -s "$TMP_WAV" ] && afplay "$TMP_WAV" 2>/dev/null
    rm -f "$TMP_WAV"
) &
exit 0
