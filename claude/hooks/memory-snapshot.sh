#!/bin/bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작 (2026-07-08, 76s 훅스택+BOOTSTRAP 오염 T1)
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
# Stop hook — 세션 종료 시 맥락 노트 자동 생성 (하이브리드 아카이브)
# NCO 프로바이더(Ollama) 사용 — Claude API 토큰 금지
#
# [하이브리드 구조 — 토론 합의 2026-04-19]
#   - context_note.md      : 최신 5개 세션만 (빠른 로딩용)
#   - context_history/     : 전체 이력 아카이브 (날짜_sN.md, 중복 제거)
#   - 메모리 인덱스: ~/.claude/projects/{key}/memory/project_auto_*.md
#
# 구분자: "<!-- SESSION_START -->" / "<!-- SESSION_END -->" 블록 단위로 관리

NOTE_GENERATOR="{{HOME}}/projects/security-kb/note-generator.sh"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
PROJECT_NAME=$(basename "$PROJECT_DIR")
DATETIME=$(date +%Y-%m-%dT%H:%M)
DATE=$(date +%Y-%m-%d)
TIME=$(date +%H%M)
CONTEXT_NOTE="${PROJECT_DIR}/context_note.md"
CONTEXT_HISTORY_DIR="${PROJECT_DIR}/context_history"

cd "$PROJECT_DIR" 2>/dev/null || exit 0

# ── git 컨텍스트 수집 ────────────────────────────────────────────────
CHANGED_FILES=$(git diff --name-only HEAD 2>/dev/null | head -20)
STAGED_FILES=$(git diff --cached --name-only 2>/dev/null | head -10)
LAST_COMMITS=$(git log -3 --pretty=format:"- %s (%h)" 2>/dev/null || echo "없음")
DIFF_STAT=$(git diff --stat HEAD 2>/dev/null | tail -5 || echo "변경 없음")
BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")

# ── 의미있는 작업 판단 ────────────────────────────────────────────────
# 기준: 파일 변경 3개+ OR (편집/NCO 사용 실적 있음 AND 최근 30분 커밋 있음)
# 단순 Q&A, 인사 세션은 스킵

_CHANGED_COUNT=$(echo "$CHANGED_FILES$STAGED_FILES" | grep -c '.' 2>/dev/null || echo 0)
_RECENT_COMMITS=$(git log --since='30 minutes ago' --oneline 2>/dev/null | wc -l | tr -d ' ')

# 세션 트래킹 파일에서 작업량 확인
_NCO_SESSION_ID="${NCO_SESSION_ID:-}"
if [ -z "$_NCO_SESSION_ID" ]; then
  _CK=$$
  for _i in 1 2 3; do
    _CK=$(ps -o ppid= -p "$_CK" 2>/dev/null | tr -d ' ')
    [ -z "$_CK" ] && break
    ps -o comm= -p "$_CK" 2>/dev/null | grep -qE '^(claude|node)$' && { _NCO_SESSION_ID="$_CK"; break; }
  done
fi
_TRACK="/tmp/nco-track-${_NCO_SESSION_ID}.json"
_DIRECT_EDITS=0; _NCO_CALLS=0
if [ -f "$_TRACK" ]; then
  _vals=$(python3 -c "import json; d=json.load(open('$_TRACK')); print(d.get('direct_edits',0), d.get('nco_calls',0))" 2>/dev/null)
  read -r _DIRECT_EDITS _NCO_CALLS <<< "$_vals"
fi

# 스킵 조건: 실질 작업 없음
_MEANINGFUL=0
[ "${_CHANGED_COUNT:-0}" -ge 3 ] && _MEANINGFUL=1
[ "${_RECENT_COMMITS:-0}" -ge 1 ] && [ "${_DIRECT_EDITS:-0}" -ge 2 ] && _MEANINGFUL=1
[ "${_RECENT_COMMITS:-0}" -ge 1 ] && [ "${_NCO_CALLS:-0}" -ge 1 ] && _MEANINGFUL=1
[ "${_RECENT_COMMITS:-0}" -ge 3 ] && _MEANINGFUL=1  # 커밋 3개+ 이면 무조건

[ "$_MEANINGFUL" -eq 0 ] && exit 0

CONTEXT_INPUT="프로젝트: ${PROJECT_NAME} | 브랜치: ${BRANCH} | 시각: ${DATETIME}

[변경된 파일]
${CHANGED_FILES}
${STAGED_FILES}

[최근 커밋 3개]
${LAST_COMMITS}

[변경 통계]
${DIFF_STAT}"

PROMPT="당신은 개발 세션 기록 전문가입니다. 아래 세션 정보를 바탕으로 맥락 노트를 작성하세요.

${CONTEXT_INPUT}

## 출력 형식 (마크다운, frontmatter 포함)

---
name: {작업 제목 — 15자 이내}
description: {한 줄 설명 — 어떤 작업을 어떤 파일/코드로 했는지, 50자 이내}
type: project
---

{작업 내용 2-4줄: 핵심 변경 사항, 수정된 파일/함수명, 달성한 결과}

**Why:** {작업 이유 한 줄}
**How to apply:** {향후 참조 시 활용 방법 한 줄}

frontmatter 블록(---)과 본문만 출력하세요."

# ── NCO 프로바이더(Ollama)로 생성 ────────────────────────────────
SUMMARY=""
if [ -f "$NOTE_GENERATOR" ]; then
    SUMMARY=$(bash "$NOTE_GENERATOR" "$PROMPT" 500 2>/dev/null)
fi

# ── AI 생성 실패 시 — git 데이터로 기본 노트 생성 (토큰 0) ──────
if [ -z "$SUMMARY" ]; then
    SUMMARY="---
name: 자동 맥락 노트 ${DATE}
description: git 데이터 기반 자동 생성 (AI 오프라인)
type: project
---

$(echo "$CHANGED_FILES" | head -5 | sed 's/^/- /')

최근 커밋: $(echo "$LAST_COMMITS" | head -2)

**Why:** AI 오프라인 — git 데이터 기반 자동 기록
**How to apply:** Ollama 온라인 시 다음 세션에서 보완됨"
fi

# ── [통일 위치 1] context_note.md + context_history/ — 하이브리드 ──
# context_note.md : 최신 5개 세션 (빠른 로딩)
# context_history/: 전체 이력 (날짜_sN.md, 중복 제거)
MAX_SESSIONS=5

mkdir -p "$CONTEXT_HISTORY_DIR"

# 새 세션 블록 구성
NEW_BLOCK="<!-- SESSION_START -->
## 세션: ${DATETIME} | ${BRANCH} | ${PROJECT_NAME}

${SUMMARY}

### 변경 파일
$(echo "$CHANGED_FILES" | sed 's/^/- /' | head -15)

### 최근 커밋
${LAST_COMMITS}
<!-- SESSION_END -->"

# ── 아카이브: 현재 context_note.md의 세션들을 context_history에 저장 ──
# 중복 제거: name+description이 같은 세션은 archive에 추가 안 함
if [ -f "$CONTEXT_NOTE" ]; then
    python3 - "$CONTEXT_NOTE" "$CONTEXT_HISTORY_DIR" "$DATE" << 'PYEOF'
import sys, re, os, hashlib

note_path = sys.argv[1]
hist_dir  = sys.argv[2]
date_str  = sys.argv[3]

text   = open(note_path, encoding='utf-8', errors='replace').read()
blocks = re.findall(r'<!-- SESSION_START -->.*?<!-- SESSION_END -->', text, re.DOTALL)

# 기존 아카이브 파일에 저장된 세션 fingerprint 집합 (중복 방지)
existing_fps = set()
for fname in os.listdir(hist_dir):
    if not fname.endswith('.md'): continue
    try:
        content = open(os.path.join(hist_dir, fname), encoding='utf-8', errors='replace').read()
        for blk in re.findall(r'<!-- SESSION_START -->.*?<!-- SESSION_END -->', content, re.DOTALL):
            name_m = re.search(r'^name:\s*(.+)$', blk, re.MULTILINE)
            desc_m = re.search(r'^description:\s*(.+)$', blk, re.MULTILINE)
            dt_m   = re.search(r'^## 세션: (.+?)$', blk, re.MULTILINE)
            key = '|'.join([
                (name_m.group(1).strip() if name_m else ''),
                (desc_m.group(1).strip()[:60] if desc_m else ''),
                (dt_m.group(1).strip()[:16] if dt_m else ''),
            ])
            existing_fps.add(key)
    except Exception:
        pass

# 새로 아카이브할 블록 선별
to_archive = []
for blk in blocks:
    name_m = re.search(r'^name:\s*(.+)$', blk, re.MULTILINE)
    desc_m = re.search(r'^description:\s*(.+)$', blk, re.MULTILINE)
    dt_m   = re.search(r'^## 세션: (.+?)$', blk, re.MULTILINE)
    key = '|'.join([
        (name_m.group(1).strip() if name_m else ''),
        (desc_m.group(1).strip()[:60] if desc_m else ''),
        (dt_m.group(1).strip()[:16] if dt_m else ''),
    ])
    if key not in existing_fps:
        to_archive.append(blk)
        existing_fps.add(key)

if not to_archive:
    sys.exit(0)

# 오늘 날짜 아카이브 파일에 추가 (날짜_sN.md)
n = 1
while os.path.exists(os.path.join(hist_dir, f'{date_str}_s{n}.md')):
    n += 1
arch_path = os.path.join(hist_dir, f'{date_str}_s{n}.md')

with open(arch_path, 'w', encoding='utf-8') as f:
    f.write(f'# Context Archive — {date_str} (s{n})\n\n')
    f.write('\n\n'.join(to_archive))
    f.write('\n')

print(f'ARCHIVED:{len(to_archive)}:{arch_path}')
PYEOF
fi

# ── context_note.md 재구성: 최신 5개만 유지 ─────────────────────
OLD_SESSIONS=""
if [ -f "$CONTEXT_NOTE" ]; then
    OLD_SESSIONS=$(python3 - "$CONTEXT_NOTE" "$MAX_SESSIONS" << 'PYEOF'
import sys, re
path, max_s = sys.argv[1], int(sys.argv[2])
text = open(path, encoding='utf-8', errors='replace').read()
blocks = re.findall(r'<!-- SESSION_START -->.*?<!-- SESSION_END -->', text, re.DOTALL)
kept = blocks[:max_s - 1]
print('\n\n'.join(kept))
PYEOF
    )
fi

# 파일 재구성: 헤더 + 신규 블록 + 기존 최신 4개
{
    echo "# System Context Note — 최신 ${MAX_SESSIONS}개 세션 (전체 이력: context_history/)"
    echo "> 마지막 갱신: $(date '+%Y-%m-%d %H:%M KST') | 프로젝트: ${PROJECT_NAME}"
    echo ""
    echo "$NEW_BLOCK"
    if [ -n "$OLD_SESSIONS" ]; then
        echo ""
        echo "$OLD_SESSIONS"
    fi
} > "$CONTEXT_NOTE"

# ── [통일 위치 2] ~/.claude 메모리 인덱스 ───────────────────────
MEM_KEY=$(echo "$PROJECT_DIR" | sed 's|/|-|g' | sed 's/^-//')
MEM_DIR="$HOME/.claude/projects/${MEM_KEY}/memory"

if [ -d "$MEM_DIR" ]; then
    MEM_FILE="${MEM_DIR}/project_auto_${DATE//-}_${TIME}.md"
    printf "%s\n" "$SUMMARY" > "$MEM_FILE"

    INDEX_FILE="${MEM_DIR}/MEMORY.md"
    if [ -f "$INDEX_FILE" ]; then
        DESC=$(echo "$SUMMARY" | grep "^description:" | sed 's/description: //' | head -c 100)
        MNAME=$(echo "$SUMMARY" | grep "^name:" | sed 's/name: //' | head -c 50)
        echo "- [${MNAME:-자동 맥락 노트 ${DATE}}]($(basename "$MEM_FILE")) — ${DESC}" >> "$INDEX_FILE"

        # 200줄 초과 시 가장 오래된 자동 항목 제거
        if [ "$(wc -l < "$INDEX_FILE")" -gt 200 ]; then
            grep -n "project_auto_" "$INDEX_FILE" | head -1 | cut -d: -f1 | \
                xargs -I{} sed -i "{}d" "$INDEX_FILE" 2>/dev/null || true
        fi
    fi
fi

# ── systemMessage 출력 ───────────────────────────────────────────
python3 -c "
import json, sys
summary = sys.argv[1]
note_file = sys.argv[2]
msg = '[맥락 노트 저장됨: ' + note_file + ']\n' + summary[:300]
print(json.dumps({'systemMessage': msg}))
" "$SUMMARY" "context_note.md"
