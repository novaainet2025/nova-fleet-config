#!/bin/bash
# SessionStart Hook — NCO 워크플로우 세션 초기화
# context_note + improvement note 로드 → 워크플로우 선언 + stage tracker 초기화

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
PROJECT_NAME=$(basename "$PROJECT_DIR")
IMPROVEMENTS_DIR="$HOME/.claude/improvements"
CONTEXT_NOTE="$HOME/projects/context_note.md"

# ── 세션 ID + stage tracker 초기화 ───────────────────────────
_CK=$$; SID=""
for _i in 1 2 3 4 5; do
  _CK=$(ps -o ppid= -p "$_CK" 2>/dev/null | tr -d ' ')
  [ -z "$_CK" ] && break
  ps -o comm= -p "$_CK" 2>/dev/null | grep -qE '^(claude|node)$' && { SID="$_CK"; break; }
done
SID="${SID:-$$}"
STAGE_FILE="/tmp/nco-stages-${SID}.json"
[ ! -f "$STAGE_FILE" ] && echo '{"discussion":false,"design":false,"implementation":false,"review":false,"gap_analysis":false,"verification":false}' > "$STAGE_FILE"

# ── 세션 baseline 스냅샷 (dirty tree 잡음 제거) ──────────────
# 위임 권고 카운트가 항상 5+ 로 시작하던 버그 픽스:
# 세션 시작 시점의 변경 파일 목록을 저장 → 이후 훅들은 'baseline 이후 변경'만 카운트
BASELINE_FILES="/tmp/nco-baseline-${SID}-files"
BASELINE_HEAD="/tmp/nco-baseline-${SID}-head"
if [ ! -f "$BASELINE_FILES" ]; then
    (cd "$PROJECT_DIR" 2>/dev/null && git diff --name-only 2>/dev/null | sort -u > "$BASELINE_FILES") || : > "$BASELINE_FILES"
    (cd "$PROJECT_DIR" 2>/dev/null && git rev-parse HEAD 2>/dev/null > "$BASELINE_HEAD") || echo "" > "$BASELINE_HEAD"
fi

# ── Ollama 로컬 모드: 간략 배너 후 종료 ─────────────────────
if [ "${NCO_OLLAMA_MODE:-0}" = "1" ]; then
    MODEL="${OLLAMA_MODEL:-unknown}"
    python3 -c "
import json, sys
msg = '\n'.join([
    '═══════════════════════════════════════════════════',
    '🤖 로컬 모델 세션 (Ollama 모드)',
    f'   모델: $MODEL  |  프로젝트: $PROJECT_NAME',
    '✅ MCP: mcp__nco-commands__nco-XXX(arguments=\'TOPIC\') 로 명령 실행',
    '   /nco-discussion → mcp__nco-commands__nco-discussion  |  /nco-task → mcp__nco-commands__nco-task',
    '═══════════════════════════════════════════════════',
])
print(json.dumps({'systemMessage': msg}))
" 2>/dev/null
    exit 0
fi

# ── NCO 상태 ─────────────────────────────────────────────────
NCO_HEALTH=$(curl -s --connect-timeout 1 --max-time 2 "http://localhost:6200/health" 2>/dev/null)
NCO_STATUS="오프라인"
[ -n "$NCO_HEALTH" ] && NCO_STATUS="온라인"

# ── context_note 핵심 추출 (최신 세션 블록만) ───────────────
CTX_SUMMARY=""
if [ -f "$CONTEXT_NOTE" ]; then
  CTX_SUMMARY=$(python3 -c "
import re, sys
text = open(sys.argv[1], encoding='utf-8', errors='replace').read()
# 누적 포맷: 첫 번째 SESSION 블록만 추출
blocks = re.findall(r'<!-- SESSION_START -->(.*?)<!-- SESSION_END -->', text, re.DOTALL)
if blocks:
    print(blocks[0].strip()[:500])
else:
    # 구 포맷 fallback
    print(text[:400])
" "$CONTEXT_NOTE" 2>/dev/null | head -c 500)
fi

# ── 최신 개선 노트 권장사항 ──────────────────────────────────
PREV_IMPROVEMENTS=""
PREV_NOTE_DATE="없음"
if [ -d "$IMPROVEMENTS_DIR" ]; then
  PREV_FILE=$(ls -t "${IMPROVEMENTS_DIR}/${PROJECT_NAME}-"*.md 2>/dev/null | grep -v INDEX | head -1)
  if [ -n "$PREV_FILE" ]; then
    PREV_NOTE_DATE=$(basename "$PREV_FILE" | sed "s/${PROJECT_NAME}-//" | sed 's/\.md//')
    PREV_IMPROVEMENTS=$(awk '/권장 개선사항/{found=1;next} found&&/^###/{exit} found{print}' "$PREV_FILE" \
      | sed '/^[[:space:]]*$/d' | head -c 400)
  fi
fi

# ── JSON으로 변수 전달 후 python3로 출력 생성 ─────────────────
PAYLOAD=$(python3 -c "
import json, sys
print(json.dumps({
    'nco_status': sys.argv[1],
    'project': sys.argv[2],
    'ctx': sys.argv[3],
    'improvements': sys.argv[4],
    'prev_date': sys.argv[5],
}))
" "$NCO_STATUS" "$PROJECT_NAME" "$CTX_SUMMARY" "$PREV_IMPROVEMENTS" "$PREV_NOTE_DATE" 2>/dev/null)

python3 -c "
import json, sys

d = json.loads(sys.argv[1])
nco_status   = d['nco_status']
project      = d['project']
ctx          = d['ctx'].strip()
improvements = d['improvements'].strip()
prev_date    = d['prev_date']

lines = ['═══════════════════════════════════════════════════']
lines.append('🚀 NCO Commander 세션 시작')
lines.append(f'   NCO 백엔드: {nco_status}  |  프로젝트: {project}')
lines.append('═══════════════════════════════════════════════════')

if ctx:
    lines.append('')
    lines.append('📋 이전 세션 맥락:')
    for ln in ctx.split('\n')[:6]:
        lines.append(f'   {ln}')

if improvements:
    lines.append('')
    lines.append(f'💡 개선 노트 권장사항 ({prev_date}):')
    for ln in improvements.split('\n')[:5]:
        lines.append(f'   {ln}')

lines.append('')
lines.append('─── 이번 세션 필수 NCO 워크플로우 ──────────────────')
lines.append('  [ ] ① 토론/설계   → Skill(nco-discussion) | nco-task opencode')
lines.append('  [ ] ② 구현 위임   → Skill(nco-task) codex | Skill(nco-team)')
lines.append('  [ ] ③ 코드 리뷰   → Skill(nco-task) cursor-agent')
lines.append('  [ ] ④ Gap 분석    → Skill(nco-gap) | Skill(nco-analyze)')
lines.append('  [ ] ⑤ 검증        → Skill(nco-task) ollama')
lines.append('─────────────────────────────────────────────────────')
lines.append('  목표: NCO 사용률 80%+  |  토론→설계→구현→리뷰→Gap 순서')
lines.append('═══════════════════════════════════════════════════')

print(json.dumps({'systemMessage': '\n'.join(lines)}))
" "$PAYLOAD" 2>/dev/null
