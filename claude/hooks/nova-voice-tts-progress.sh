#!/bin/bash
# nova-voice-tts-progress.sh — PostToolUse: "XXX 작업이 완료됐습니다"
SETTINGS_FILE="$HOME/Library/Application Support/nova-voice/nova-settings.json"
DEBOUNCE_FILE="/tmp/nova-tts-progress-ts"
LOG="/tmp/nova-tts-hook.log"

# nova-voice PTY 세션 전용 게이트 — 앱이 심는 NOVA_VOICE_SESSION=1 없으면 무음
[ "${NOVA_VOICE_SESSION:-}" != "1" ] && exit 0

NOW=$(date +%s)
LAST=$(cat "$DEBOUNCE_FILE" 2>/dev/null || echo 0)
[ $(( NOW - LAST )) -lt 4 ] && exit 0

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
resp = data.get('tool_response',{}) or {}

err = ''
if isinstance(resp, dict):
    err = resp.get('error','') or resp.get('stderr','') or ''
is_err = bool(str(err).strip())

def project_name(text):
    text = str(text)
    proj_map = [
        (r'nova-voice', '노바 보이스'),
        (r'claude/hooks|\.claude/hooks', '클로드 훅'),
        (r'\.claude/settings|settings\.json', '클로드 설정'),
        (r'/opt/homebrew|brew\b', '홈브루'),
        (r'venv|\.venv|site-packages', '파이썬 환경'),
    ]
    for pattern, name in proj_map:
        if re.search(pattern, text, re.I):
            return name
    m = re.search(r'/project/([^/\s]+)', text)
    if m: return m.group(1)
    m = re.search(r'/([^/]+)/src/', text)
    if m: return m.group(1)
    return ''

def src_area(path):
    area_map = [
        (r'/main/tts[-_]client', 'TTS 엔진'),
        (r'/main/ipc', 'IPC 핸들러'),
        (r'/main/pipeline', 'TTS 파이프라인'),
        (r'/main/shortcuts', '단축키'),
        (r'/main/index', '메인 프로세스'),
        (r'/main/', '메인 프로세스'),
        (r'/components/settings', '설정 UI'),
        (r'/components/unified', '메인 패널'),
        (r'/components/home', '홈 화면'),
        (r'/renderer/hooks', '렌더러 훅'),
        (r'/renderer/stores', '상태 저장소'),
        (r'/preload', '프리로드'),
        (r'/renderer/', '렌더러'),
        (r'hooks/', '훅 스크립트'),
    ]
    for pattern, name in area_map:
        if re.search(pattern, path, re.I):
            return name
    return ''

def func_hint(old_str, new_str):
    """변경된 함수명/키워드 추출"""
    combined = (str(old_str) + ' ' + str(new_str))[:200]
    # 한국어 키워드
    ko = re.findall(r'[가-힣]{2,8}', combined)
    if ko: return ko[0]
    # 함수명/변수명 (camelCase, snake_case)
    funcs = re.findall(r'\b(cancel\w+|record\w+|speak\w+|tts\w+|audio\w+|\w+Recording|\w+TTS|\w+Voice)\b', combined, re.I)
    if funcs: return funcs[0][:20]
    # 일반 식별자
    ids = re.findall(r'\b([a-zA-Z][a-zA-Z0-9]{3,20})\b', combined)
    if ids: return ids[0]
    return ''

def stdout_summary(resp):
    """응답에서 의미있는 한줄 추출"""
    out = str(resp.get('output','') or resp.get('stdout','')).strip()
    if not out: return ''
    lines = [l.strip() for l in out.split('\n') if l.strip()]
    for line in lines[:5]:
        if len(line) < 8: continue
        ko_r = len(re.findall(r'[가-힣]', line)) / max(len(line),1)
        if ko_r >= 0.2 and len(line) <= 60:
            return line
        # 영어지만 의미있는 결과 (에러메시지, 완료메시지)
        if re.search(r'error|warn|success|done|built|pass|fail', line, re.I) and len(line) <= 50:
            return line
    return ''

if tool == 'Bash':
    cmd = str(inp.get('command','')).strip()
    cl = cmd.lower()
    if 'afplay' in cl or 'nova-tts' in cl: sys.exit(0)
    if re.search(r'curl.*localhost.*:(7860|8800|8801|8802)', cmd): sys.exit(0)

    proj = project_name(cmd)
    proj_s = f'{proj} ' if proj else ''

    if is_err:
        first = cmd.split('\n')[0].strip()[:35]
        clean = re.sub(r'[|<>&${}\\\'"#]','',first).strip()
        msg = f'{proj_s}{clean[:25]} 실행 중 오류가 발생했습니다' if len(clean)>3 else f'{proj_s}명령 실행 중 오류가 발생했습니다'

    elif re.search(r'npm run build|bun run build|yarn build|electron-vite build', cl):
        # 빌드 출력에서 결과 추출
        out = str(resp.get('output','') or '').strip()
        time_m = re.search(r'built in ([\d.]+\w+)', out)
        size_m = re.search(r'(\d+[\d.]*\s*[kKmM]B)', out)
        detail = ''
        if time_m: detail = f' ({time_m.group(1)})'
        elif size_m: detail = f' ({size_m.group(1)})'
        msg = f'{proj_s}빌드가 완료됐습니다{detail}'

    elif re.search(r'tsc\b|--noemit', cl):
        out = str(resp.get('output','') or '').strip()
        err_count = len(re.findall(r'error TS', out))
        if err_count:
            msg = f'{proj_s}타입 검사 완료: {err_count}개 오류 발견'
        else:
            msg = f'{proj_s}타입 검사 완료: 오류 없음'

    elif re.search(r'npm run dev|bun dev|yarn dev', cl):
        msg = f'{proj_s}개발 서버가 시작됐습니다'

    elif re.search(r'git commit', cl):
        m2 = re.search(r'-m\s*["\']([^"\']{3,50})', cmd)
        if m2:
            msg = f'{proj_s}커밋 완료: {m2.group(1)[:35]}'
        else:
            msg = f'{proj_s}커밋이 완료됐습니다'

    elif re.search(r'git push', cl):
        msg = f'{proj_s}원격 저장소에 푸시됐습니다'

    elif re.search(r'git add\b', cl):
        sys.exit(0)

    elif re.search(r'npm install|pip install|yarn add|bun add|brew install', cl):
        m2 = re.search(r'(?:install|add)\s+([\w@/\-\.]+)', cmd)
        pkg = m2.group(1)[:20] if m2 else ''
        msg = f'{pkg} 패키지 설치가 완료됐습니다' if pkg else f'{proj_s}패키지 설치가 완료됐습니다'

    elif re.search(r'pytest|jest|vitest|npm test|bun test', cl):
        out = str(resp.get('output','') or '').strip()
        p = re.search(r'(\d+)\s*(?:passed|tests? passed|✓|✅)', out)
        f2 = re.search(r'(\d+)\s*(?:failed|FAILED|✗|❌)', out)
        if f2 and p: msg = f'{proj_s}테스트 완료: {p.group(1)}개 통과, {f2.group(1)}개 실패'
        elif f2: msg = f'{proj_s}테스트 완료: {f2.group(1)}개 실패'
        elif p: msg = f'{proj_s}테스트 완료: {p.group(1)}개 통과'
        else: msg = f'{proj_s}테스트가 완료됐습니다'

    elif re.search(r'cat\s*>', cmd) or re.search(r'<<\s*[\'"]?\w{2,}', cmd):
        m2 = re.search(r'cat\s*[>]+\s*["\']?([\S]+)', cmd)
        if m2:
            p2 = project_name(m2.group(1))
            a = src_area(m2.group(1))
            fn = os.path.basename(m2.group(1))[:15]
            loc = f'{p2} {a}'.strip() if p2 and a else (p2 or a or fn)
            msg = f'{loc} 파일 작성이 완료됐습니다'
        else:
            msg = f'{proj_s}파일 작성이 완료됐습니다'

    elif re.search(r'chmod', cl):
        m2 = re.search(r'chmod\s+\S+\s+([\S]+)', cmd)
        if m2:
            fn = os.path.basename(m2.group(1))[:20]
            msg = f'{fn} 파일 권한을 설정했습니다'
        else:
            msg = '파일 권한 설정이 완료됐습니다'

    elif re.search(r'mkdir', cl):
        m2 = re.search(r'mkdir.*?\s([\w\-\.]+)\s*$', cmd)
        msg = f'{m2.group(1)[:15]} 폴더를 생성했습니다' if m2 else '폴더를 생성했습니다'

    elif re.search(r'\bcp\b|\brsync\b', cl): msg = f'{proj_s}파일 복사가 완료됐습니다'
    elif re.search(r'\bmv\b', cl): msg = f'{proj_s}파일 이동이 완료됐습니다'
    elif re.search(r'\brm\b', cl): msg = '파일을 삭제했습니다'

    else:
        # stdout 한국어 한줄
        ko_line = stdout_summary(resp)
        if ko_line:
            msg = ko_line
        else:
            first = cmd.split('\n')[0].split('&&')[0].strip()
            clean = re.sub(r'[|<>&${}\\\'"#]','',first).strip()
            if 4 <= len(clean) <= 25 and not re.search(r'[./\-]{2,}', clean):
                msg = f'{proj_s}{clean} 실행이 완료됐습니다'
            else:
                sys.exit(0)

elif tool == 'Edit':
    path = str(inp.get('file_path',''))
    proj = project_name(path)
    area = src_area(path)
    fn_raw = os.path.basename(path)
    # 파일명 자연어
    fn_alias = {
        'tts-client': 'TTS 클라이언트', 'ipc': 'IPC', 'pipeline': '파이프라인',
        'SettingsPanel': '설정 패널', 'UnifiedPanel': '유니파이드 패널',
        'App': '앱', 'index': '인덱스', 'shortcuts': '단축키',
        'useRecorder': '레코더 훅', 'appStore': '앱 스토어',
        'nova-voice-tts-progress': '프로그래스 훅',
        'nova-voice-tts-pretool': '프리툴 훅',
        'nova-voice-tts': 'TTS 훅',
    }
    fn_base = re.sub(r'\.(ts|tsx|js|jsx|py|sh|json)$','',fn_raw)
    fn = next((v for k,v in fn_alias.items() if k.lower() in fn_raw.lower()), fn_base[:15])

    old_s = inp.get('old_string','') or ''
    new_s = inp.get('new_string','') or ''
    hint = func_hint(old_s, new_s)

    loc = f'{proj} {area}'.strip() if proj and area else (proj or area or '')
    if hint and loc:
        msg = f'{loc}의 {fn} 파일에서 {hint} 부분을 수정했습니다'
    elif hint:
        msg = f'{fn} 파일에서 {hint} 부분을 수정했습니다'
    elif loc:
        msg = f'{loc}의 {fn} 파일 수정이 완료됐습니다'
    else:
        msg = f'{fn} 파일 수정이 완료됐습니다'

elif tool == 'MultiEdit':
    path = str(inp.get('file_path',''))
    proj = project_name(path)
    area = src_area(path)
    edits = inp.get('edits',[]) or []
    fn_raw = os.path.basename(path)
    fn_base = re.sub(r'\.(ts|tsx|js|jsx|py|sh|json)$','',fn_raw)[:15]
    loc = f'{proj} {area}'.strip() if proj and area else (proj or area or fn_base)
    count = len(edits)
    msg = f'{loc} 파일에서 {count}군데 수정이 완료됐습니다' if count else f'{loc} 파일 수정이 완료됐습니다'

elif tool == 'Write':
    path = str(inp.get('file_path',''))
    proj = project_name(path)
    area = src_area(path)
    content_str = str(inp.get('content','') or '')
    fn_raw = os.path.basename(path)
    fn_base = re.sub(r'\.(ts|tsx|js|jsx|py|sh|json)$','',fn_raw)[:15]
    loc = f'{proj} {area}'.strip() if proj and area else (proj or area or fn_base)
    lines = content_str.count('\n') + 1 if content_str else 0
    msg = f'{loc} 파일을 {lines}줄로 작성했습니다' if lines > 5 else f'{loc} 파일 작성이 완료됐습니다'

elif tool == 'WebSearch':
    q = str(inp.get('query','')).strip()[:30]
    msg = f'"{q}" 검색이 완료됐습니다' if q else '웹 검색이 완료됐습니다'

elif tool == 'WebFetch':
    url = str(inp.get('url','')).replace('https://','').replace('http://','')
    domain = url.split('/')[0][:25]
    msg = f'{domain} 페이지 로드가 완료됐습니다' if domain else '웹 페이지 로드가 완료됐습니다'

elif tool == 'Agent':
    desc = str(inp.get('description','') or '')[:35]
    msg = f'에이전트 작업이 완료됐습니다: {desc}' if desc else '에이전트 작업이 완료됐습니다'

elif tool in ('Grep','Read','Glob','LS'):
    sys.exit(0)

else:
    sys.exit(0)

print(msg[:100])
PYEOF2
)

rm -f "$TMP_JSON"
[ -z "$MSG" ] && exit 0
echo "$NOW" > "$DEBOUNCE_FILE"
echo "[$(date +%H:%M:%S)] post: $MSG" >> "$LOG"

(
    TMP_WAV="/tmp/nova-tts-prog-$$.wav"
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
        AUDIO_JSON=$(curl -s --connect-timeout 3 --max-time 20 -X POST -H "Content-Type: application/json" -d "$PAYLOAD" "${TTS_API}/api/voices/qwen3-tts/tts" 2>/dev/null)
        AUDIO_URL=$(echo "$AUDIO_JSON" | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('url',''))
except: pass" 2>/dev/null)
        [ -z "$AUDIO_URL" ] && exit 0
        HTTP_CODE=$(curl -s --connect-timeout 3 --max-time 20 -w "%{http_code}" -o "$TMP_WAV" "${TTS_API}${AUDIO_URL}" 2>/dev/null)
    else
        ROUTE_MODEL=$(curl -s --max-time 2 "${TTS_API}/v1/models" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'] if d.get('data') else '')" 2>/dev/null || echo "")
        [ -z "$ROUTE_MODEL" ] && exit 0
        TMP_PAY="/tmp/nova-payload-prog-$$.json"
        v="$TTS_VOICE"
        [ -n "$v" ] && python3 -c "import json,sys; p={'model':sys.argv[1],'input':sys.argv[2],'voice':sys.argv[3],'response_format':'wav'}; open(sys.argv[4],'w').write(json.dumps(p))" "$ROUTE_MODEL" "$MSG" "$v" "$TMP_PAY" 2>/dev/null \
                    || python3 -c "import json,sys; p={'model':sys.argv[1],'input':sys.argv[2],'response_format':'wav'}; open(sys.argv[3],'w').write(json.dumps(p))" "$ROUTE_MODEL" "$MSG" "$TMP_PAY" 2>/dev/null
        HTTP_CODE=$(curl -s --connect-timeout 3 --max-time 20 -w "%{http_code}" -o "$TMP_WAV" -X POST -H "Content-Type: application/json" -d "@$TMP_PAY" "${TTS_API}/v1/audio/speech" 2>/dev/null)
        rm -f "$TMP_PAY"
    fi
    [ "$HTTP_CODE" = "200" ] && [ -s "$TMP_WAV" ] && afplay "$TMP_WAV" 2>/dev/null
    rm -f "$TMP_WAV"
) &
exit 0
