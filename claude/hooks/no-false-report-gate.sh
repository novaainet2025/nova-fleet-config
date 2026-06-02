#!/bin/bash
# Stop Hook: 거짓·미검증 보고 방지 5-Gate
# ---------------------------------------------------------------
# 5중 게이트:
#   [G1] PreReportGate     — 완료성 단어 + 실행 증거 매칭
#   [G2] VerificationReceipt — '## 검증 영수증' 섹션 강제 (코드 수정 turn)
#   [G3] SentinelWords      — 검증 영수증 외 단독 완료 선언 차단
#   [G4] UIVisualCheck      — UI 파일 변경 시 시각 증거 강제
#   [G5] MemoryEnforce      — feedback_no_false_reports.md 해시 검증
#
# 모드 (환경변수 NCO_FALSE_REPORT_MODE):
#   warn  (기본) → 위반 시 stderr 경고 + exit 0 (학습용)
#   block         → 위반 시 stderr 에러 + exit 2 (강제 재실행)
#   off           → 게이트 스킵
#
# 카운터: ~/.claude/.false-report-count (위반 누적, statusline 노출용)

set -u

echo "[$(date +%H:%M:%S)] HOOK_START no-false-report-gate.sh" >> /tmp/claude-hook-trace.log
trap 'echo "[$(date +%H:%M:%S)] HOOK_END   no-false-report-gate.sh exit=$?" >> /tmp/claude-hook-trace.log' EXIT

MODE="${NCO_FALSE_REPORT_MODE:-warn}"
[ "$MODE" = "off" ] && exit 0

INPUT=$(cat 2>/dev/null)
COUNTER_FILE="$HOME/.claude/.false-report-count"
MEM_FILE="$HOME/.claude/projects/-home-nova-projects/memory/feedback_no_false_reports.md"
HASH_FILE="$HOME/.claude/.false-report-memhash"

# ── transcript path 추출 ────────────────────────────────────────
TRANSCRIPT_PATH=$(echo "$INPUT" | python3 -c "
import sys, json
try: print(json.load(sys.stdin).get('transcript_path',''))
except: pass
" 2>/dev/null)

# transcript 없으면 게이트 무효 (다른 hook과 정합)
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
    exit 0
fi

# ── 마지막 user prompt 이후의 assistant text + tool_use 추출 ──────
ANALYSIS=$(python3 <<PYEOF 2>/dev/null
import json, sys, re

TRANSCRIPT = "$TRANSCRIPT_PATH"
EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
# 검증 증거로 인정하는 tool. 실제 실행/관찰을 동반하는 것만.
EVIDENCE_TOOLS = {"Bash", "Read", "Grep", "Glob", "WebFetch", "WebSearch"}

try:
    lines = open(TRANSCRIPT, encoding='utf-8', errors='replace').readlines()
except Exception:
    print("ERR")
    sys.exit(0)

# 마지막 real user prompt 인덱스
last_user = -1
for i in range(len(lines) - 1, -1, -1):
    try:
        d = json.loads(lines[i])
        if d.get('type') != 'user': continue
        if 'toolUseResult' in d: continue
        # system-reminder만 있는 user 메시지는 스킵
        msg = d.get('message') or {}
        content = msg.get('content', '')
        if isinstance(content, list):
            text = ' '.join(c.get('text','') for c in content if isinstance(c, dict))
        else:
            text = str(content)
        # 시스템 리마인더만 있고 실제 prompt 없으면 skip
        if not text.strip() or text.strip().startswith('<system-reminder>'):
            continue
        last_user = i
        break
    except Exception:
        pass

# 이후 assistant 메시지 모으기
asst_text = []
tool_uses = []
tool_results = []
for i in range(last_user + 1, len(lines)):
    try:
        d = json.loads(lines[i])
        if d.get('type') == 'assistant':
            content = (d.get('message') or {}).get('content', [])
            if not isinstance(content, list): continue
            for c in content:
                if not isinstance(c, dict): continue
                if c.get('type') == 'text':
                    asst_text.append(c.get('text',''))
                elif c.get('type') == 'tool_use':
                    tool_uses.append({
                        'name': c.get('name',''),
                        'input': c.get('input', {})
                    })
        elif d.get('type') == 'user' and 'toolUseResult' in d:
            r = d.get('toolUseResult', {})
            if isinstance(r, dict):
                content = r.get('content', '') or r.get('stdout', '')
                if isinstance(content, list):
                    content = ' '.join(str(x.get('text','')) if isinstance(x, dict) else str(x) for x in content)
                tool_results.append(str(content)[:2000])
            else:
                tool_results.append(str(r)[:2000])
    except Exception:
        pass

full_text = '\n'.join(asst_text)

# 완료성 키워드 (한글·영어·이모지 우회 포함)
COMPLETION_PATTERNS = [
    r'완\s*료(?!\s*예정|\s*전|\s*후|\s*시까지)',
    r'성\s*공(?!\s*률|\s*하면|\s*적인)',
    r'\b(?:PASS|PASSED|DONE|FIXED|RESOLVED|COMPLETE[D]?|FINISHED|WORKING)\b',
    r'100\s*[%％]',
    r'정\s*상\s*(?:작\s*동|동\s*작|완\s*료)',
    r'해\s*결\s*(?:됨|완료|완료됨)',
    r'끝\s*났\s*(?:어요|습니다|음)',
    r'✅',
]

# 영수증/검증 표식 (영수증 안에서는 완료어 허용)
RECEIPT_HEADER = re.compile(r'^##\s*검증\s*영수증\s*$', re.MULTILINE)
RECEIPT_FIELDS = [
    r'(?:^|\n)\s*-?\s*\[?\s*변경\s*\]?',
    r'(?:^|\n)\s*-?\s*\[?\s*검증\s*방법\s*\]?',
    r'(?:^|\n)\s*-?\s*\[?\s*Gap\s*\]?',
]

# 정보-only 응답인가? (코드 수정 없음)
edits_this_turn = sum(1 for t in tool_uses if t['name'] in EDIT_TOOLS)
evidence_this_turn = sum(1 for t in tool_uses if t['name'] in EVIDENCE_TOOLS)

# 완료성 단어 탐지
completion_hits = []
for pat in COMPLETION_PATTERNS:
    if re.search(pat, full_text, flags=re.IGNORECASE):
        completion_hits.append(pat)

# Receipt 섹션 확인
has_receipt = bool(RECEIPT_HEADER.search(full_text))
receipt_fields_ok = all(re.search(p, full_text, re.IGNORECASE) for p in RECEIPT_FIELDS) if has_receipt else False

# UI 파일 변경 탐지 (Edit/Write/MultiEdit input의 file_path)
ui_files = []
for t in tool_uses:
    if t['name'] not in EDIT_TOOLS: continue
    inp = t.get('input', {})
    fp = inp.get('file_path', '') or inp.get('notebook_path', '')
    if re.search(r'\.(tsx|jsx|vue|html|css|scss|svelte)$', fp, re.IGNORECASE):
        ui_files.append(fp)

# 시각 증거 (screenshot 파일 언급, localhost 응답, http://)
visual_evidence = bool(re.search(r'(screenshot|스크린샷|localhost:|http://127\.|http://localhost)', full_text + ' '.join(tool_results), re.IGNORECASE))

# 최종 분석 결과
result = {
    'edits': edits_this_turn,
    'evidence_calls': evidence_this_turn,
    'completion_words': completion_hits,
    'has_receipt': has_receipt,
    'receipt_fields_ok': receipt_fields_ok,
    'ui_files': ui_files,
    'visual_evidence': visual_evidence,
    'asst_text_len': len(full_text),
}
print(json.dumps(result, ensure_ascii=False))
PYEOF
)

if [ -z "$ANALYSIS" ] || [ "$ANALYSIS" = "ERR" ]; then
    exit 0
fi

# 결과 파싱
EDITS=$(echo "$ANALYSIS"     | python3 -c "import json,sys;print(json.load(sys.stdin)['edits'])" 2>/dev/null || echo 0)
EVIDENCE=$(echo "$ANALYSIS"  | python3 -c "import json,sys;print(json.load(sys.stdin)['evidence_calls'])" 2>/dev/null || echo 0)
COMP_HITS=$(echo "$ANALYSIS" | python3 -c "import json,sys;print(len(json.load(sys.stdin)['completion_words']))" 2>/dev/null || echo 0)
HAS_RECEIPT=$(echo "$ANALYSIS" | python3 -c "import json,sys;print('1' if json.load(sys.stdin)['has_receipt'] else '0')" 2>/dev/null || echo 0)
RECEIPT_OK=$(echo "$ANALYSIS"  | python3 -c "import json,sys;print('1' if json.load(sys.stdin)['receipt_fields_ok'] else '0')" 2>/dev/null || echo 0)
UI_FILES=$(echo "$ANALYSIS"  | python3 -c "import json,sys;print(len(json.load(sys.stdin)['ui_files']))" 2>/dev/null || echo 0)
VISUAL=$(echo "$ANALYSIS"    | python3 -c "import json,sys;print('1' if json.load(sys.stdin)['visual_evidence'] else '0')" 2>/dev/null || echo 0)

VIOLATIONS=()

# ─── G1: PreReportGate ──────────────────────────────────────────
# 완료성 단어가 있는데 같은 턴에 어떤 실행 도구도 안 썼으면 차단
if [ "$COMP_HITS" -gt 0 ] && [ "$EDITS" -eq 0 ] && [ "$EVIDENCE" -eq 0 ]; then
    VIOLATIONS+=("[G1] 완료성 단어 감지(${COMP_HITS}건)되었으나 같은 turn에 Edit/Bash/Read 등 실행/관찰 도구를 호출하지 않음. 실제 검증 없는 보고로 추정.")
fi

# ─── G2: VerificationReceipt ────────────────────────────────────
# 코드 수정이 있었으면 '## 검증 영수증' 섹션 필수
if [ "$EDITS" -gt 0 ]; then
    if [ "$HAS_RECEIPT" = "0" ]; then
        VIOLATIONS+=("[G2] 코드 수정 ${EDITS}건 발생했으나 '## 검증 영수증' 섹션이 응답에 없음.")
    elif [ "$RECEIPT_OK" = "0" ]; then
        VIOLATIONS+=("[G2] '## 검증 영수증' 섹션은 있으나 필수 필드(변경/검증방법/Gap) 일부 누락.")
    fi
fi

# ─── G3: SentinelWords ──────────────────────────────────────────
# 정보-only turn에만 적용 (edits>0이면 G2가 Receipt 누락을 처리)
# 완료어가 있는데 Receipt도 없고 코드 수정도 없으면: 검증 없는 완료 선언으로 추정
if [ "$COMP_HITS" -gt 0 ] && [ "$HAS_RECEIPT" = "0" ] && [ "$EDITS" = "0" ]; then
    VIOLATIONS+=("[G3] 완료성 단어 단독 사용(검증 영수증 없음). 보고에는 반드시 영수증 섹션 동반 필요.")
fi

# ─── G4: UIVisualCheck ──────────────────────────────────────────
if [ "$UI_FILES" -gt 0 ] && [ "$VISUAL" = "0" ]; then
    VIOLATIONS+=("[G4] UI 파일(${UI_FILES}개) 수정했으나 시각 증거(screenshot/localhost 응답) 부재. 실제 렌더링 확인 누락 의심.")
fi

# ─── G5: MemoryEnforce ──────────────────────────────────────────
if [ -f "$MEM_FILE" ]; then
    CUR_HASH=$(sha256sum "$MEM_FILE" 2>/dev/null | awk '{print $1}')
    PREV_HASH=$(cat "$HASH_FILE" 2>/dev/null || echo "")
    if [ -n "$PREV_HASH" ] && [ "$PREV_HASH" != "$CUR_HASH" ]; then
        # 메모리 파일 변경됨 — 의도적 업데이트일 수도 있으므로 알림만
        echo "[G5] feedback_no_false_reports.md 해시 변경 감지 (정상 업데이트일 수 있음)" >&2
    fi
    echo "$CUR_HASH" > "$HASH_FILE" 2>/dev/null
fi

# ── 결과 처리 ──────────────────────────────────────────────────
if [ ${#VIOLATIONS[@]} -eq 0 ]; then
    exit 0
fi

# 카운터 증가
COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
COUNT=$((COUNT + 1))
echo "$COUNT" > "$COUNTER_FILE" 2>/dev/null

# 출력
{
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "🚫 거짓·미검증 보고 차단 게이트 위반 (모드: $MODE, 누적: $COUNT회)"
    echo "════════════════════════════════════════════════════════════"
    for v in "${VIOLATIONS[@]}"; do
        echo "  • $v"
    done
    echo ""
    echo "📋 필수 조치:"
    echo "  1. 실제 검증 도구 호출 (Bash로 실행 / Read로 결과 확인 / curl로 응답 확인)"
    echo "  2. 응답에 '## 검증 영수증' 섹션 포함:"
    echo "     ## 검증 영수증"
    echo "     - [변경] file:line — what was changed"
    echo "     - [검증방법] curl/Bash/Read 출력 발췌 + timestamp"
    echo "     - [Gap] N% (실제 완료율)"
    echo "     - [미검증항목] (있다면 명시, 없으면 '없음')"
    echo "  3. 미검증 사항은 절대 '완료/PASS/100%'로 보고하지 말고 '미검증'으로 명시"
    echo ""
    if [ "$MODE" = "block" ]; then
        echo "❌ BLOCK 모드 — 차단됨. 위 조치 수행 후 다시 응답 작성."
    else
        echo "⚠️  WARN 모드 — 통과시키되 패턴 기록. block 모드 전환: export NCO_FALSE_REPORT_MODE=block"
    fi
    echo "════════════════════════════════════════════════════════════"
} >&2

if [ "$MODE" = "block" ]; then
    exit 2
fi

exit 0
