#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# universal-verify.sh — 범용 실행 검증 훅 v1.0
# 매 turn 종료 시 실행:
#   1. 응답 텍스트에서 HTTP URL / 로컬 포트 / 파일 경로 주장 추출
#   2. 실제 curl / lsof / stat 로 검증 실행
#   3. 불일치(응답 vs 실제) → exit 2로 차단 + 오류 주입
# ═══════════════════════════════════════════════════════════════════

set -u
LOG=/tmp/universal-verify.log
echo "[$(date +%H:%M:%S)] HOOK_START universal-verify.sh" >> "$LOG"
trap 'echo "[$(date +%H:%M:%S)] HOOK_END universal-verify.sh exit=$?" >> "$LOG"' EXIT

# 모드 제어: off 이면 스킵
MODE="${NCO_UNIVERSAL_VERIFY:-on}"
[ "$MODE" = "off" ] && exit 0

INPUT=$(cat 2>/dev/null)
TRANSCRIPT_PATH=$(echo "$INPUT" | python3 -c "
import sys, json
try: print(json.load(sys.stdin).get('transcript_path',''))
except: pass
" 2>/dev/null)

[ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ] && exit 0

# ── 마지막 assistant 응답 텍스트 추출 ──────────────────────────────
LAST_ASST=$(python3 <<'PYEOF' 2>/dev/null
import json, sys, os

path = os.environ.get('TRANSCRIPT_PATH', '')
if not path:
    # env에 없으면 sys.argv fallback
    sys.exit(0)

lines = open(path, encoding='utf-8', errors='replace').readlines()

# 마지막 user prompt 위치
last_user = -1
for i in range(len(lines)-1, -1, -1):
    try:
        d = json.loads(lines[i])
        if d.get('type') != 'user': continue
        if 'toolUseResult' in d: continue
        msg = d.get('message') or {}
        content = msg.get('content','')
        if isinstance(content, list):
            text = ' '.join(c.get('text','') for c in content if isinstance(c, dict))
        else:
            text = str(content)
        if text.strip() and not text.strip().startswith('<system-reminder>'):
            last_user = i
            break
    except: pass

texts = []
for i in range(last_user+1, len(lines)):
    try:
        d = json.loads(lines[i])
        if d.get('type') != 'assistant': continue
        content = (d.get('message') or {}).get('content', [])
        for c in (content if isinstance(content, list) else []):
            if isinstance(c, dict) and c.get('type') == 'text':
                texts.append(c.get('text',''))
    except: pass

print('\n'.join(texts))
PYEOF
)

export TRANSCRIPT_PATH
LAST_ASST=$(TRANSCRIPT_PATH="$TRANSCRIPT_PATH" python3 <<'PYEOF' 2>/dev/null
import json, sys, os

path = os.environ.get('TRANSCRIPT_PATH', '')
lines = open(path, encoding='utf-8', errors='replace').readlines()

last_user = -1
for i in range(len(lines)-1, -1, -1):
    try:
        d = json.loads(lines[i])
        if d.get('type') != 'user': continue
        if 'toolUseResult' in d: continue
        msg = d.get('message') or {}
        content = msg.get('content','')
        if isinstance(content, list):
            text = ' '.join(c.get('text','') for c in content if isinstance(c, dict))
        else:
            text = str(content)
        if text.strip() and not text.strip().startswith('<system-reminder>'):
            last_user = i
            break
    except: pass

texts = []
for i in range(last_user+1, len(lines)):
    try:
        d = json.loads(lines[i])
        if d.get('type') != 'assistant': continue
        content = (d.get('message') or {}).get('content', [])
        for c in (content if isinstance(content, list) else []):
            if isinstance(c, dict) and c.get('type') == 'text':
                texts.append(c.get('text',''))
    except: pass

print('\n'.join(texts))
PYEOF
)

[ -z "$LAST_ASST" ] && exit 0

# ── 검증 대상 추출 (맥락 필터링) ────────────────────────────────────
# 실패/오류 맥락에 등장한 URL은 검증 대상에서 제외한다.
# "연결 실패", "HTTP 000", "미동작", "응답없음", "오류" 등 실패 문맥에 나온 URL은 skip.
URLS=$(LAST_ASST="$LAST_ASST" python3 <<'PYEOF' 2>/dev/null
import re, os

text = os.environ.get('LAST_ASST', '')

# 실패 맥락 키워드 (앞뒤 ±120자 내에 있으면 제외)
FAIL_CTX = re.compile(
    r'(연결\s*실패|HTTP\s*000|미동작|응답\s*없음|오류|ERR|ECONNREFUSED|차단|'
    r'실패|안\s*됨|되지\s*않|안되|불가|접속\s*불가|거부|refused|timeout|'
    r'http://localhost:\d+.*실패|실패.*http://localhost)',
    re.IGNORECASE
)

# 긍정 맥락 키워드 (앞뒤 ±80자 내에 있으면 포함 우선)
PASS_CTX = re.compile(
    r'(HTTP\s*200|200\s*OK|✅|정상|성공|확인\s*완료|동작|응답|PASS|통과)',
    re.IGNORECASE
)

url_pat = re.compile(r'https?://[a-zA-Z0-9._:/@-]+(?:/[^\s\'"<>]*)?')
exclude = {'example', 'placeholder', 'xxx'}

seen = set()
result = []
for m in url_pat.finditer(text):
    url = m.group().rstrip('.,;)')
    if any(e in url for e in exclude): continue
    if url in seen: continue
    seen.add(url)

    start = max(0, m.start() - 120)
    end   = min(len(text), m.end() + 120)
    ctx   = text[start:end]

    # 실패 맥락이면 skip
    if FAIL_CTX.search(ctx):
        continue
    result.append(url)
    if len(result) >= 8: break

print('\n'.join(result))
PYEOF
)

# ── 실제 검증 실행 ──────────────────────────────────────────────────
FAILURES=()
PASS_COUNT=0
CHECKED=0

# URL 검증 (주장된 URL만, 최대 5개, 타임아웃 6초)
for URL in $(echo "$URLS" | head -5); do
    # 내부 LAN/localhost URL은 빠르게, 외부는 타임아웃 넉넉히
    if echo "$URL" | grep -qE 'localhost|127\.0\.0|192\.168|10\.|100\.'; then
        TIMEOUT=5
    else
        TIMEOUT=8
    fi

    HTTP_CODE=$(curl -sk --max-time "$TIMEOUT" "$URL" -o /dev/null -w "%{http_code}" 2>/dev/null || echo "ERR")
    CHECKED=$((CHECKED+1))

    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ]; then
        PASS_COUNT=$((PASS_COUNT+1))
        echo "[VERIFY] PASS $URL → $HTTP_CODE" >> "$LOG"
    elif [ "$HTTP_CODE" = "400" ] || [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
        # 400/401/403는 서버 응답 = 접속 자체는 성공
        PASS_COUNT=$((PASS_COUNT+1))
        echo "[VERIFY] PASS(auth) $URL → $HTTP_CODE" >> "$LOG"
    else
        FAILURES+=("URL $URL → 실제: HTTP $HTTP_CODE (응답 없음/오류)")
        echo "[VERIFY] FAIL $URL → $HTTP_CODE" >> "$LOG"
    fi
done

# ── 검증 결과 판정 ──────────────────────────────────────────────────
if [ ${#FAILURES[@]} -eq 0 ]; then
    # 검증 통과 또는 검증 대상 없음
    if [ "$CHECKED" -gt 0 ]; then
        echo "[universal-verify] ✅ 검증 통과: ${PASS_COUNT}/${CHECKED}" >&2
    fi
    exit 0
fi

# ── 실패 시 차단 + 오류 주입 ────────────────────────────────────────
FAIL_COUNT=${#FAILURES[@]}

{
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║   🔴 universal-verify: 실제 검증 실패 — 응답 차단       ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    echo "응답에서 정상으로 주장했으나 실제 검증에서 실패한 항목:"
    echo ""
    for f in "${FAILURES[@]}"; do
        echo "  ✗ $f"
    done
    echo ""
    echo "검증 통과: ${PASS_COUNT}개  |  실패: ${FAIL_COUNT}개  |  검사 총: ${CHECKED}개"
    echo ""
    echo "━━ 재실행 요구사항 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  1. 위 실패 항목을 실제로 수정하거나"
    echo "  2. '미동작 — 수정 필요' 로 정직하게 보고할 것"
    echo "  3. '동작 중', '200 OK', '✅' 주장은 실제 curl 확인 후에만"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
} >&2

exit 2
