#!/bin/bash
# nova-voice-tts.sh — Stop 훅: 마지막 어시스턴트 응답 요약 → TTS
# ⚠️  목소리 통일 정책: settings의 ttsModel+mlxVoice만 사용

SETTINGS_FILE="$HOME/Library/Application Support/nova-voice/nova-settings.json"
LOG="/tmp/nova-tts-hook.log"

TTS_CONFIG=$(python3 -c "
import json
QWEN3_MAP={'Ryan':'ryan','Chelsie':'sohee','Vivian':'vivian','Aiden':'aiden',
           'Ethan':'uncle_fu','Serena':'serena','Eric':'eric','Dylan':'dylan'}
KOKORO_MAP={'Ryan':'am_adam','Chelsie':'af_bella','Vivian':'af_heart','Aiden':'am_adam',
            'Ethan':'bm_george','Serena':'bf_emma','Eric':'am_adam','Dylan':'bm_george'}
SPARK_MAP={'Ryan':'zh_male_M0001','Chelsie':'zh_female_M0003','Vivian':'zh_female_M0004',
           'Aiden':'zh_male_M0002','Ethan':'zh_male_M0005','Serena':'zh_female_M0006',
           'Eric':'zh_male_M0007','Dylan':'zh_male_M0008'}
try:
    with open('$SETTINGS_FILE') as f:
        d = json.load(f)
    model = d.get('ttsModel','all_tts')
    vu = d.get('mlxVoice','Serena')
except:
    model,vu = 'all_tts','Serena'
if model=='all_tts':
    adapter = d.get('allTtsAdapter','edge_tts') if 'd' in dir() else 'edge_tts'
    voice = d.get('allTtsVoice','ko-KR-SunHiNeural') if 'd' in dir() else 'ko-KR-SunHiNeural'
    api,mode,vid='http://localhost:7861','all_tts',f'{adapter}|{voice}'
elif model=='qwen3': api,mode,vid='http://localhost:7860','qwen3',QWEN3_MAP.get(vu,'serena')
elif model in('mlx','mlx_ko'): api,mode,vid='http://localhost:8800','openai',''
elif model=='mlx_en': api,mode,vid='http://localhost:8801','openai',KOKORO_MAP.get(vu,'bf_emma')
elif model=='mlx_mix': api,mode,vid='http://localhost:8802','openai',SPARK_MAP.get(vu,'zh_female_M0006')
else: api,mode,vid='http://localhost:7861','all_tts','edge_tts|ko-KR-SunHiNeural'
print(f'{model}|{api}|{mode}|{vid}')
" 2>/dev/null || echo "all_tts|http://localhost:7861|all_tts|edge_tts|ko-KR-SunHiNeural")

TTS_MODEL=$(echo "$TTS_CONFIG" | cut -d'|' -f1)
TTS_API=$(echo "$TTS_CONFIG" | cut -d'|' -f2)
TTS_MODE=$(echo "$TTS_CONFIG" | cut -d'|' -f3)
TTS_VOICE=$(echo "$TTS_CONFIG" | cut -d'|' -f4)
# all_tts 모드: vid 필드가 "adapter|voice" 형식
ALL_TTS_ADAPTER=""
ALL_TTS_VOICE=""
if [ "$TTS_MODE" = "all_tts" ]; then
    ALL_TTS_ADAPTER=$(echo "$TTS_VOICE" | cut -d'|' -f1)
    ALL_TTS_VOICE=$(echo "$TTS_VOICE" | cut -d'|' -f2)
    # 5번째 필드가 있으면 (파이프라인 파싱 보정)
    FIELD5=$(echo "$TTS_CONFIG" | cut -d'|' -f5)
    if [ -n "$FIELD5" ]; then
        ALL_TTS_ADAPTER=$(echo "$TTS_CONFIG" | cut -d'|' -f4)
        ALL_TTS_VOICE="$FIELD5"
    fi
fi

echo "[$(date +%H:%M:%S)] TTS CONFIG: model=$TTS_MODEL api=$TTS_API mode=$TTS_MODE voice=$TTS_VOICE adapter=$ALL_TTS_ADAPTER all_voice=$ALL_TTS_VOICE" >> "$LOG"

TMP_JSON=$(mktemp /tmp/nova-hook-XXXXXX)
cat > "$TMP_JSON"

CHUNKS=$(python3 - "$TMP_JSON" << 'EOF'
import json, sys, re

try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception:
    sys.exit(0)

raw = data.get('last_assistant_message', '').strip()
if not raw or len(raw) < 5:
    sys.exit(0)

if raw.startswith('{') and raw.endswith('}'):
    try:
        json.loads(raw)
        sys.exit(0)
    except:
        pass

text = raw

# 코드 블록 제거
text = re.sub(r'```[\s\S]*?```', ' ', text)
text = re.sub(r'`[^`\n]+`', ' ', text)

# 라인별 필터
lines = text.split('\n')
clean = []
for line in lines:
    s = line.strip()
    if not s:
        continue
    if re.match(r'^(#!/|cat\s*[>|]|chmod|curl\b|python3?\b|pip3?\b|npm\b|bun\b|tee\b|mkdir|rm\b|cp\b|mv\b|ln\b|echo\b|export\b|source\b|if\s*\[|fi$|done$|while\b|for\b|do$|then$|else$|elif\b|\s*[|&]{1,2}|\s*#)', s):
        continue
    alnum_ko = len(re.findall(r'[가-힣a-zA-Z0-9\s.,!?\-~]', s))
    if len(s) > 5 and alnum_ko / len(s) < 0.45:
        continue
    if re.match(r'^\s*https?://\S+\s*$', s):
        continue
    # --- 구분선 제거
    if re.match(r'^[-—─=*]{3,}\s*$', s):
        continue
    clean.append(s)

text = ' '.join(clean)

# 마크다운 제거
text = re.sub(r'\*\*([^*]+)\*\*', r'\1', text)
text = re.sub(r'\*([^*]+)\*', r'\1', text)
text = re.sub(r'^#{1,6}\s+', '', text, flags=re.M)
text = re.sub(r'^[-*•]\s+', '', text, flags=re.M)
text = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', text)
text = re.sub(r'https?://\S+', '', text)
text = re.sub(r'!\[.*?\]\(.*?\)', '', text)
text = re.sub(r'\|[^\n]+', '', text)
text = re.sub(r'(?<!\w)[~/.][\w./\-]{3,}', '', text)
text = re.sub(r'\b[0-9a-f]{8,}\b', '', text)
text = re.sub(r'\([^가-힣\n]{5,}\)', '', text)
text = re.sub(r'\s{2,}', ' ', text).strip()

if len(text) < 8:
    sys.exit(0)

# 문단/문장 분리 — 번호목록(\n)도 경계로 인식
# 먼저 \n\n(문단)으로 나누고, 각 문단을 문장으로 재분리
paras = re.split(r'\n{2,}', text)
sents_raw = []
for para in paras:
    para = para.strip()
    if not para:
        continue
    # 번호목록 헤더(\n + 숫자.)도 경계
    sub = re.split(r'(?<=[.!?。！？다요죠어네지며고])\s+|(?=\d+[.．]\s+[가-힣A-Za-z])', para)
    sents_raw.extend(sub)

ko_sents, other_sents = [], []
for s in sents_raw:
    s = s.strip()
    if len(s) < 6:
        continue
    ko_ratio = len(re.findall(r'[가-힣]', s)) / max(len(s), 1)
    if ko_ratio >= 0.15:
        ko_sents.append(s)
    else:
        other_sents.append(s)

candidates = ko_sents if ko_sents else other_sents

# ── 요약 전략: 첫 완전한 문장 → 200자 내 → 안내 멘트 ──
# 원칙: 항상 완전한 문장 단위로 끝냄. 잘렸으면 "화면 확인" 안내 추가.
MAX_SENT_CHARS = 200  # 단일 문장 최대 길이

if not candidates:
    final = text[:MAX_SENT_CHARS]
    truncated = len(text) > MAX_SENT_CHARS
else:
    first = candidates[0]
    if len(first) <= MAX_SENT_CHARS:
        # 첫 문장이 짧음 → 그대로 사용
        final = first
        truncated = len(candidates) > 1  # 뒤에 더 내용 있으면 안내
    else:
        # 첫 문장이 긺 → 200자 내 마지막 문장 경계에서 자름
        sub = first[:MAX_SENT_CHARS]
        last_b = max(sub.rfind('다'), sub.rfind('요'), sub.rfind('죠'),
                     sub.rfind('.'), sub.rfind('?'), sub.rfind('!'))
        if last_b > 20:
            final = first[:last_b+1]
        else:
            final = sub
        truncated = True

# 잘린 경우 안내 멘트 추가 — 맥락 없이 끊기는 대신 명시적으로 안내
if truncated:
    final = final + ' 자세한 내용은 화면을 확인해주세요.'

# 청크 분할 100자 — 공백 기준으로 단어 경계에서만 자름
CHUNK_MAX = 100
MIN_CHUNK = 8  # 이 미만 단편은 다음 청크에 합침

def split_at_word_boundary(text, max_len):
    """max_len 이내의 마지막 공백에서 분리 — 단어 중간 자름 없음"""
    if len(text) <= max_len:
        return text, ''
    cut = text.rfind(' ', 0, max_len)
    if cut <= 0:
        cut = max_len  # 공백 없으면 어쩔 수 없이 글자 단위
    return text[:cut].strip(), text[cut:].strip()

sents = re.split(r'(?<=[.!?。！？다요며고서죠어네지])\s+', final)
chunks = []
cur = ''
for s in sents:
    s = s.strip()
    if not s:
        continue
    if len(cur) + len(s) + 1 <= CHUNK_MAX:
        cur = (cur + ' ' + s).strip()
    else:
        if cur:
            chunks.append(cur)
        # 긴 문장 → 공백 기준 분할
        remaining = s
        while len(remaining) > CHUNK_MAX:
            head, remaining = split_at_word_boundary(remaining, CHUNK_MAX)
            if head:
                chunks.append(head)
        cur = remaining
if cur:
    chunks.append(cur)
if not chunks:
    chunks = [final[:CHUNK_MAX]]

# 짧은 단편 청크 병합 (MIN_CHUNK 미만은 인접 청크에 붙임)
merged = []
for c in chunks:
    if merged and len(c) < MIN_CHUNK:
        merged[-1] = (merged[-1] + ' ' + c).strip()
    else:
        merged.append(c)
# 첫 청크도 짧으면 다음 청크 앞에 붙임
if len(merged) >= 2 and len(merged[0]) < MIN_CHUNK:
    merged[1] = (merged[0] + ' ' + merged[1]).strip()
    merged = merged[1:]
chunks = [c for c in merged if c.strip()]

import sys as _sys
_sys.argv  # dummy
for c in chunks:
    if c.strip():
        print(c.strip())
EOF
)

rm -f "$TMP_JSON"
[ -z "$CHUNKS" ] && exit 0

CHUNK_COUNT=$(echo "$CHUNKS" | grep -c .)
if [ "$TTS_MODE" = "all_tts" ]; then
    echo "[$(date +%H:%M:%S)] TTS[all_tts/${ALL_TTS_ADAPTER}/${ALL_TTS_VOICE}] ${CHUNK_COUNT}청크: $(echo "$CHUNKS" | head -1 | cut -c1-60)" >> "$LOG"
else
    echo "[$(date +%H:%M:%S)] TTS[$TTS_MODEL/$TTS_VOICE] ${CHUNK_COUNT}청크: $(echo "$CHUNKS" | head -1 | cut -c1-60)" >> "$LOG"
fi

if [ "$TTS_MODE" = "all_tts" ]; then
    # all-tts Hub health check (:7861) — 다운이어도 침묵 금지: launchd 재기동 → say 폴백
    _tts_healthy() {
        curl -s --connect-timeout 2 --max-time 3 "${TTS_API}/health" 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('status')=='ok'" 2>/dev/null
    }
    if ! _tts_healthy; then
        echo "[$(date +%H:%M:%S)] all-tts 서버 다운 — launchd 재기동 시도" >> "$LOG"
        launchctl kickstart -k "gui/$(id -u)/com.nova.all-tts" 2>/dev/null \
            || launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.nova.all-tts.plist" 2>/dev/null
        for _i in 1 2 3 4 5 6; do sleep 1; _tts_healthy && break; done
    fi
    if ! _tts_healthy; then
        _KO_VOICES=$(say -v '?' 2>/dev/null | awk '/ko_KR/{print $1}')
        SAY_VOICE=$(echo "$_KO_VOICES" | grep -m1 -x Yuna || echo "$_KO_VOICES" | head -1)
        echo "[$(date +%H:%M:%S)] all-tts 복구 실패 — macOS say 폴백 (voice=${SAY_VOICE:-default})" >> "$LOG"
        echo "$CHUNKS" | say ${SAY_VOICE:+-v "$SAY_VOICE"} 2>/dev/null
        exit 0
    fi
    ROUTE_MODEL=""
elif [ "$TTS_MODE" = "qwen3" ]; then
    ! curl -s --connect-timeout 1 --max-time 2 "${TTS_API}/health" > /dev/null 2>&1 && exit 0
    ROUTE_MODEL=""
else
    ROUTE_MODEL=$(curl -s --max-time 2 "${TTS_API}/v1/models" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'] if d.get('data') else '')" 2>/dev/null || echo "")
    [ -z "$ROUTE_MODEL" ] && exit 0
fi

# ── 중복 TTS 방지: 이전 TTS 프로세스 kill + lock 획득 ──
LOCK_FILE="/tmp/nova-tts.lock"
# 이전 TTS 오케스트레이터가 살아있으면 kill (afplay 포함)
if [ -f "$LOCK_FILE" ]; then
    OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        kill -- -"$OLD_PID" 2>/dev/null || kill "$OLD_PID" 2>/dev/null
        # 해당 프로세스가 띄운 afplay만 정리될 수 있도록 잠시 대기
        sleep 0.2
        pkill -x afplay 2>/dev/null
        echo "[$(date +%H:%M:%S)] 이전 TTS(pid=$OLD_PID) kill → 새 TTS로 교체" >> "$LOG"
    fi
fi
# lock 파일 없으면 afplay kill 하지 않음 (단일 CLI 첫 실행 시 중지 방지)

# 병렬 합성 + 순서대로 재생 — Python 오케스트레이터
# os.setsid()로 새 프로세스 그룹 생성 → 훅 35초 타임아웃 이후에도 재생 생존
CHUNKS_FILE=$(mktemp /tmp/nova-chunks-XXXXXX)
printf '%s' "$CHUNKS" > "$CHUNKS_FILE"

TTS_MODE="$TTS_MODE" TTS_API="$TTS_API" TTS_VOICE="$TTS_VOICE" \
    ROUTE_MODEL="${ROUTE_MODEL:-}" \
    ALL_TTS_ADAPTER="${ALL_TTS_ADAPTER:-edge_tts}" ALL_TTS_VOICE="${ALL_TTS_VOICE:-ko-KR-SunHiNeural}" \
    python3 - "$CHUNKS_FILE" "$LOG" "$TTS_MODEL" << 'PYEOF' >/dev/null 2>&1 &
import sys, os, json, subprocess, threading, tempfile, time, urllib.request, urllib.parse, signal

# 새 프로세스 그룹 — 훅 타임아웃에도 생존
try: os.setsid()
except: pass

# Lock 파일에 PID 기록 — 다음 훅 호출이 이 프로세스를 kill 할 수 있도록
LOCK_FILE = "/tmp/nova-tts.lock"
MY_PID = os.getpid()
with open(LOCK_FILE, "w") as _lf:
    _lf.write(str(MY_PID))

def _check_still_owner():
    """내가 여전히 TTS 오너인지 확인 (다른 CLI가 lock을 뺏으면 조용히 종료)"""
    try:
        with open(LOCK_FILE) as f:
            return f.read().strip() == str(MY_PID)
    except:
        return False

chunks_file = sys.argv[1]
log_path    = sys.argv[2]
tts_model   = sys.argv[3] if len(sys.argv) > 3 else "qwen3"
mode        = os.environ.get("TTS_MODE", "all_tts")
api         = os.environ.get("TTS_API", "http://localhost:7861")
voice       = os.environ.get("TTS_VOICE", "serena")
route_model = os.environ.get("ROUTE_MODEL", "")
all_adapter = os.environ.get("ALL_TTS_ADAPTER", "edge_tts")
all_voice   = os.environ.get("ALL_TTS_VOICE", "ko-KR-SunHiNeural")

def log(msg):
    try:
        ts = time.strftime("%H:%M:%S")
        with open(log_path, "a") as f:
            f.write(f"[{ts}] {msg}\n")
    except: pass

# 청크 로드
try:
    with open(chunks_file) as f:
        raw = f.read()
    os.unlink(chunks_file)
except:
    sys.exit(0)

chunks = [l.strip() for l in raw.splitlines() if l.strip()]
if not chunks:
    sys.exit(0)

n = len(chunks)
wavs   = [None] * n
events = [threading.Event() for _ in range(n)]

# Qwen3-TTS는 단일 스레드 서버 — 병렬 요청 시 큐 대기로 타임아웃 발생
# → 1-ahead 파이프라인: 현재 청크 재생 중에 다음 청크 합성 (동시 요청 최대 1개)
SYNTH_TIMEOUT = 90  # 서버 큐 대기 포함 여유 있는 타임아웃

def synth_qwen3(idx, text):
    try:
        payload = json.dumps({"text": text, "speaker": voice, "lang": "ko"}).encode()
        req = urllib.request.Request(
            f"{api}/api/voices/qwen3-tts/tts",
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST"
        )
        with urllib.request.urlopen(req, timeout=SYNTH_TIMEOUT) as r:
            resp = json.loads(r.read())
        url = resp.get("url", "")
        if not url:
            log(f"chunk{idx+1} qwen3 url 없음"); return
        fd, wav = tempfile.mkstemp(suffix=".wav", prefix=f"nova-tts-{idx+1}-")
        os.close(fd)
        with urllib.request.urlopen(f"{api}{url}", timeout=SYNTH_TIMEOUT) as r:
            data = r.read()
        with open(wav, "wb") as f:
            f.write(data)
        if os.path.getsize(wav) > 0:
            wavs[idx] = wav
            log(f"chunk{idx+1} ready: {text[:40]}")
        else:
            os.unlink(wav)
            log(f"chunk{idx+1} 빈 WAV")
    except Exception as e:
        log(f"chunk{idx+1} qwen3 오류: {e}")
    finally:
        events[idx].set()

def synth_openai(idx, text):
    try:
        if not route_model:
            log(f"chunk{idx+1} route_model 없음"); return
        payload = {"model": route_model, "input": text, "response_format": "wav"}
        if voice:
            payload["voice"] = voice
        data = json.dumps(payload).encode()
        req = urllib.request.Request(
            f"{api}/v1/audio/speech",
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST"
        )
        fd, wav = tempfile.mkstemp(suffix=".wav", prefix=f"nova-tts-{idx+1}-")
        os.close(fd)
        with urllib.request.urlopen(req, timeout=SYNTH_TIMEOUT) as r:
            with open(wav, "wb") as f:
                f.write(r.read())
        if os.path.getsize(wav) > 0:
            wavs[idx] = wav
            log(f"chunk{idx+1} ready: {text[:40]}")
        else:
            os.unlink(wav)
            log(f"chunk{idx+1} 빈 WAV")
    except Exception as e:
        log(f"chunk{idx+1} openai 오류: {e}")
    finally:
        events[idx].set()

def synth_all_tts(idx, text):
    """all-tts Hub SSE 스트리밍 → MP3 파일 저장"""
    try:
        params = urllib.parse.urlencode({
            "text": text, "adapter": all_adapter,
            "voice": all_voice, "speaker": all_voice,
            "speed": "1.0", "format": "mp3"
        })
        url = f"{api}/api/stream?{params}"
        req = urllib.request.Request(url, method="GET")
        fd, mp3 = tempfile.mkstemp(suffix=".mp3", prefix=f"nova-tts-{idx+1}-")
        os.close(fd)
        audio_chunks = []
        with urllib.request.urlopen(req, timeout=SYNTH_TIMEOUT) as r:
            buf = b""
            for line in r:
                buf += line
                # SSE: "event: audio\ndata: <base64>\n\n"
                while b"\n\n" in buf:
                    msg, buf = buf.split(b"\n\n", 1)
                    lines = msg.decode("utf-8", errors="replace").strip().split("\n")
                    ev_type, ev_data = "", ""
                    for l in lines:
                        if l.startswith("event:"):
                            ev_type = l[6:].strip()
                        elif l.startswith("data:"):
                            ev_data = l[5:].strip()
                    if ev_type == "audio" and ev_data:
                        import base64
                        audio_chunks.append(base64.b64decode(ev_data))
                    elif ev_type == "done":
                        break
        if audio_chunks:
            with open(mp3, "wb") as f:
                for c in audio_chunks:
                    f.write(c)
            if os.path.getsize(mp3) > 0:
                wavs[idx] = mp3
                log(f"chunk{idx+1} all-tts ready [{all_adapter}]: {text[:40]}")
            else:
                os.unlink(mp3)
                log(f"chunk{idx+1} all-tts 빈 파일")
        else:
            os.unlink(mp3)
            log(f"chunk{idx+1} all-tts 오디오 청크 없음")
    except Exception as e:
        log(f"chunk{idx+1} all-tts 오류: {e}")
    finally:
        events[idx].set()

if mode == "all_tts":
    synth_fn = synth_all_tts
elif mode == "qwen3":
    synth_fn = synth_qwen3
else:
    synth_fn = synth_openai

# 1-ahead 파이프라인:
# - chunk 0 합성 시작
# - chunk 0 완료 대기 → 재생 시작 + chunk 1 합성 시작 (동시)
# - chunk 0 재생 완료 → chunk 1 완료 대기 → 재생 + chunk 2 합성
# → 합성과 재생이 겹쳐서 갭 최소화, 서버에는 항상 1개 요청만
t0 = threading.Thread(target=synth_fn, args=(0, chunks[0]), daemon=True)
t0.start()

for i in range(n):
    # 매 청크 전 lock 소유권 확인 — 다른 CLI가 뺏었으면 조용히 종료
    if not _check_still_owner():
        log(f"chunk{i+1} lock 상실 — 새 TTS에 양보, 종료")
        break

    # 현재 청크 준비 대기 (합성 완료)
    events[i].wait(timeout=SYNTH_TIMEOUT + 10)

    # 다음 청크 합성 미리 시작 (현재 재생 중에 합성 진행)
    if i + 1 < n:
        tn = threading.Thread(target=synth_fn, args=(i+1, chunks[i+1]), daemon=True)
        tn.start()

    # 현재 청크 재생
    wav = wavs[i]
    if wav and os.path.exists(wav):
        try:
            subprocess.run(["afplay", wav], timeout=120)
        except: pass
        try: os.unlink(wav)
        except: pass
    else:
        log(f"chunk{i+1} 재생 건너뜀 (WAV 없음)")

# 정상 종료 시 lock 정리
if _check_still_owner():
    try: os.unlink(LOCK_FILE)
    except: pass
log(f"TTS 재생 완료 ({n}청크)")
PYEOF

disown $!
exit 0
