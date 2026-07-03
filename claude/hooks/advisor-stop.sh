#!/bin/bash
# Stop hook — 세션 종료 시 개선 노트 생성 (before/after 포함)
# NCO 프로바이더(Ollama) 사용 — Claude API 토큰 금지
#
# [통일된 위치]
#   - ~/.claude/improvements/{project}-{date}-{time}.md
#   - docs/improvements/{project}-{date}-{time}.md (프로젝트 내)

NOTE_GENERATOR="/Users/nova-ai/projects/security-kb/note-generator.sh"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
PROJECT_NAME=$(basename "$PROJECT_DIR")
DATETIME=$(date +%Y-%m-%dT%H:%M)
DATE=$(date +%Y-%m-%d)
TIME=$(date +%H%M)
IMPROVEMENTS_DIR="$HOME/.claude/improvements"

cd "$PROJECT_DIR" 2>/dev/null || cd "$HOME/projects" 2>/dev/null

# ── 의미있는 작업 판단 ────────────────────────────────────────────
# 기준 (OR 조건): 최근 1시간 커밋 2개+ | 편집 3회+ | NCO 1회+ AND 편집 1회+
# 단순 Q&A·인사 세션은 스킵 (커밋 전/후 모두 올바르게 감지)

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
  _vals=$(python3 -c "import json; d=json.load(open('$_TRACK')); print(d.get('direct_edits',0), d.get('nco_calls',0))" 2>/dev/null || echo "0 0")
  read -r _DIRECT_EDITS _NCO_CALLS <<< "$_vals"
fi
_RECENT_COMMITS=$(git log --since='1 hour ago' --oneline 2>/dev/null | wc -l | tr -d ' ')
_UNSTAGED=$(git diff --name-only 2>/dev/null | wc -l | tr -d ' ')

_MEANINGFUL=0
[ "${_RECENT_COMMITS:-0}" -ge 2 ] && _MEANINGFUL=1
[ "${_DIRECT_EDITS:-0}" -ge 3 ] && _MEANINGFUL=1
[ "${_NCO_CALLS:-0}" -ge 1 ] && [ "${_DIRECT_EDITS:-0}" -ge 1 ] && _MEANINGFUL=1
[ "${_UNSTAGED:-0}" -ge 3 ] && _MEANINGFUL=1

[ "$_MEANINGFUL" -eq 0 ] && exit 0

# ── git 컨텍스트 수집 ────────────────────────────────────────────
GIT_DIFF_STAT=$(git diff --stat HEAD 2>/dev/null | tail -8 || echo "변경 없음")
LAST_COMMITS=$(git log -5 --pretty=format:"- %s (%h, %ad)" --date=short 2>/dev/null || echo "없음")
CHANGED_FILES=$(git diff --name-only HEAD 2>/dev/null | head -15)
STAGED_FILES=$(git diff --cached --name-only 2>/dev/null | head -10)
BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")

# ── 이전 개선 노트 읽기 (before 추출 + 중복 감지) ──────────────
PREV_FILE=$(ls -t "${IMPROVEMENTS_DIR}/${PROJECT_NAME}-"*.md 2>/dev/null | grep -v INDEX | head -1)
PREV_PENDING=""
PREV_DATE=""
PREV_COMMITS=""
if [ -n "$PREV_FILE" ]; then
    PREV_PENDING=$(awk '/미완성|미작업/{found=1; next} found && /^###/{exit} found{print}' "$PREV_FILE" 2>/dev/null | head -c 600 || true)
    PREV_DATE=$(basename "$PREV_FILE" | sed "s/${PROJECT_NAME}-//" | sed 's/\.md//')
    # 이전 노트의 커밋 목록 추출 (중복 감지용)
    PREV_COMMITS=$(grep -oE '[a-f0-9]{7,}\b' "$PREV_FILE" 2>/dev/null | sort | tr '\n' ' ')
fi

# 중복 감지: 현재 세션 커밋이 이전 노트와 완전히 동일하면 스킵
_CUR_COMMITS=$(echo "$LAST_COMMITS" | grep -oE '[a-f0-9]{7,}\b' | sort | tr '\n' ' ')
# PREV_COMMITS가 비어 있어도 헤더의 "커밋:" 줄에서 재추출 시도
if [ -z "$PREV_COMMITS" ] && [ -n "$PREV_FILE" ]; then
    PREV_COMMITS=$(grep '^> 커밋:' "$PREV_FILE" 2>/dev/null | sed 's/^> 커밋: *//')
fi
if [ -n "$PREV_COMMITS" ] && [ -n "$_CUR_COMMITS" ] && [ "$PREV_COMMITS" = "$_CUR_COMMITS" ]; then
    exit 0  # 동일한 커밋셋 → 중복 노트 생성 안 함
fi

PROMPT="당신은 시니어 코드 리뷰어 겸 아키텍트입니다. 아래 세션 정보를 바탕으로 개선 노트를 작성하세요.

프로젝트: ${PROJECT_NAME} | 브랜치: ${BRANCH} | 시각: ${DATETIME}

[변경된 파일]
${CHANGED_FILES}
${STAGED_FILES}

[최근 커밋 5개]
${LAST_COMMITS}

[변경 통계]
${GIT_DIFF_STAT}

[이전 세션 미완료 항목 — Before]
${PREV_PENDING:-없음}

## 출력 형식 (마크다운)

### ✅ 이번 작업 요약
(한 줄)

### 🔄 Before → After (이번 세션에서 개선된 사항)
| 이전 문제 | 이번 해결 | 파일/코드 |
|-----------|-----------|-----------|
| ...       | ...       | ...       |

### 🚧 미완성·미작업 항목
- (구체적 파일/기능명 포함)

### 🔒 보안 검토
- (취약점, 인증, 입력검증 등)

### ⚡ 최적화 가능 항목
- (성능, 불필요한 연산, 캐싱 기회 등)

### 🏗️ 아키텍처·설계 개선
- (구조적 문제, 책임 분리 등)

### ⚠️ 비평·비판
- (솔직하게 — 무엇이 잘못되었는가)

### 💡 다음 세션 권장 개선사항 (우선순위순)
각 항목에 반드시 [High], [Medium], [Low] 중 하나의 태그를 붙일 것.
1. [High] ...
2. [Medium] ...
3. [Low] ...

### 📊 품질 평가
점수: X/10 | 이유: (한 줄)"

# ── NCO 프로바이더(Ollama)로 생성 — 3-tier 폴백 ─────────────────
# Tier 1: note-generator.sh (존재 시)
# Tier 2: 직접 Ollama API (:11434)
# Tier 3: MLX 프록시 (:4100)
REVIEW=""
if [ -f "$NOTE_GENERATOR" ]; then
    REVIEW=$(bash "$NOTE_GENERATOR" "$PROMPT" 800 2>/dev/null)
fi

# Tier 2: 직접 Ollama API — qwen3:32b 또는 사용 가능한 첫 모델
if [ -z "$REVIEW" ]; then
    _OLLAMA_MODEL=$(curl -s http://localhost:11434/api/tags 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); ms=d.get('models',[]); print(ms[0]['name'] if ms else '')" 2>/dev/null)
    if [ -n "$_OLLAMA_MODEL" ]; then
        REVIEW=$(curl -s -m 60 http://localhost:11434/api/generate \
            -H "Content-Type: application/json" \
            -d "$(python3 -c "import json,sys; print(json.dumps({'model': sys.argv[1], 'prompt': sys.argv[2], 'stream': False, 'options': {'num_predict': 800}}))" \
                "$_OLLAMA_MODEL" "$PROMPT")" 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('response',''))" 2>/dev/null)
    fi
fi

# Tier 3: MLX 프록시 (:4100)
if [ -z "$REVIEW" ]; then
    REVIEW=$(curl -s -m 60 http://localhost:4100/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d "$(python3 -c "import json,sys; print(json.dumps({'model':'local','messages':[{'role':'user','content':sys.argv[1]}],'max_tokens':800}))" \
            "$PROMPT")" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])" 2>/dev/null)
fi

# ── AI 실패 시 기본 노트 — git 데이터 기반 구조화 ─────────────────
if [ -z "$REVIEW" ]; then
    _CHANGED_LIST=$(echo "$CHANGED_FILES" | head -5 | sed 's/^/- /' | tr '\n' '|' | sed 's/|$//')
    _COMMIT_CNT=$(echo "$LAST_COMMITS" | grep -c '^-' || echo 0)
    REVIEW="### ✅ 이번 작업 요약
AI 오프라인 — git 데이터 기반 자동 기록 (커밋 ${_COMMIT_CNT}건)

### 🔄 Before → After
| 이전 문제 | 이번 해결 | 파일/코드 |
|-----------|-----------|-----------|
$(echo "$LAST_COMMITS" | head -3 | sed 's/^- /| / ; s/$/ | - | - |/')

### 🚧 미완성·미작업 항목
$(echo "$CHANGED_FILES" | head -5 | sed 's/^/- /')

### 💡 다음 세션 권장 개선사항
1. [High] Ollama 온라인 시 advisor-stop.sh 재실행으로 상세 분석
2. [Medium] 변경 파일 $(echo "$CHANGED_FILES" | wc -l | tr -d ' ')개 코드 리뷰 진행

### 📊 품질 평가
점수: -/10 | 이유: AI 오프라인 (Ollama/MLX 미응답)"
fi

# ── [통일 위치 1] ~/.claude/improvements/ 저장 ─────────────────
mkdir -p "$IMPROVEMENTS_DIR"
NOTE_FILE="${IMPROVEMENTS_DIR}/${PROJECT_NAME}-${DATE}-${TIME}.md"

cat > "$NOTE_FILE" << NOTEOF
# 개선 노트 — ${PROJECT_NAME}
> 생성: ${DATETIME} | 브랜치: ${BRANCH}
> 이전 노트: ${PREV_DATE:-없음}
> 커밋: ${_CUR_COMMITS}

${REVIEW}
NOTEOF

# ── [통일 위치 2] docs/improvements/ 저장 ───────────────────────
if [ -d "${PROJECT_DIR}/docs" ] && [ -w "${PROJECT_DIR}/docs" ]; then
    mkdir -p "${PROJECT_DIR}/docs/improvements"
    cp "$NOTE_FILE" "${PROJECT_DIR}/docs/improvements/$(basename "$NOTE_FILE")"
fi

# ── 인덱스 업데이트 ──────────────────────────────────────────────
INDEX_FILE="${IMPROVEMENTS_DIR}/IMPROVEMENTS-INDEX.md"
SUMMARY_LINE=$(echo "$REVIEW" | grep -A1 "이번 작업 요약" | tail -1 | sed 's/^[[:space:]]*//' | head -c 80)
echo "- [${DATETIME}] **${PROJECT_NAME}** — ${SUMMARY_LINE} → \`$(basename "$NOTE_FILE")\`" >> "$INDEX_FILE"
if [ "$(wc -l < "$INDEX_FILE" 2>/dev/null || echo 0)" -gt 30 ]; then
    tail -30 "$INDEX_FILE" > "${INDEX_FILE}.tmp" && mv "${INDEX_FILE}.tmp" "$INDEX_FILE"
fi

# ── systemMessage 출력 ───────────────────────────────────────────
python3 -c "
import json, sys
review = sys.argv[1]
note_file = sys.argv[2]
msg = '[개선 노트 저장됨: ' + note_file + ']\n\n' + review[:500]
print(json.dumps({'systemMessage': msg}))
" "$REVIEW" "$(basename "$NOTE_FILE")"

# ── [High] 항목 → context_note.md 자동 삽입 ────────────────────
CONTEXT_NOTE="${PROJECT_DIR}/context_note.md"
if [ -f "$CONTEXT_NOTE" ]; then
    HIGH_ITEMS=$(echo "$REVIEW" | grep -oP '\[High\][^\n]+' 2>/dev/null | head -3 | sed 's/^/- /')
    if [ -n "$HIGH_ITEMS" ]; then
        # 이미 "필수 인지" 섹션이 있으면 교체, 없으면 추가
        if grep -q "## 5\. 다음 세션 필수 인지" "$CONTEXT_NOTE" 2>/dev/null; then
            python3 - "$CONTEXT_NOTE" "$HIGH_ITEMS" << 'PYEOF'
import sys, re
path = sys.argv[1]
items = sys.argv[2]
text = open(path, encoding='utf-8').read()
section = f"## 5. 다음 세션 필수 인지\n{items}\n"
text = re.sub(r'## 5\. 다음 세션 필수 인지.*?(?=\n## |\Z)', section, text, flags=re.DOTALL)
open(path, 'w', encoding='utf-8').write(text)
PYEOF
        else
            printf '\n## 5. 다음 세션 필수 인지\n%s\n' "$HIGH_ITEMS" >> "$CONTEXT_NOTE"
        fi
    fi
fi

# ── Ollama 모드 거짓 보고 감지 ─────────────────────────────────
# 모델이 NCO 도구 실행을 주장했지만 실제 호출 기록이 없으면 경고 출력
if [ "${NCO_OLLAMA_MODE:-0}" = "1" ]; then
    # 실제 NCO 호출 횟수 확인
    _ACTUAL_NCO=0
    if [ -f "$_TRACK" ]; then
        _ACTUAL_NCO=$(python3 -c "
import json
try: print(json.load(open('$_TRACK')).get('nco_calls', 0))
except: print(0)
" 2>/dev/null || echo 0)
    fi

    # REVIEW 텍스트에서 거짓 NCO 실행 주장 감지
    _FALSE_CLAIM=0
    if echo "$REVIEW" | grep -qiE '(nco|토론|위임|병렬).*(실행|완료|진행|중입니다|되었습니다)'; then
        [ "$_ACTUAL_NCO" -eq 0 ] && _FALSE_CLAIM=1
    fi

    if [ "$_FALSE_CLAIM" -eq 1 ]; then
        python3 -c "
import json
msg = '[⚠ 거짓 보고 감지]\n로컬 모델이 NCO 도구 실행을 주장했으나 실제 호출 기록이 없습니다.\n실제 NCO 호출: 0회 — 응답을 신뢰하지 마세요.'
print(json.dumps({'systemMessage': msg}))
" 2>/dev/null
    fi
fi

# ── 주기적 통합 (7일마다, 오래된 파일 5개+ 시) ──────────────────
CONSOLIDATE_SCRIPT="/Users/nova-ai/projects/security-kb/notes-consolidate.sh"
[ -f "$CONSOLIDATE_SCRIPT" ] && bash "$CONSOLIDATE_SCRIPT" "$PROJECT_NAME" 2>/dev/null &
