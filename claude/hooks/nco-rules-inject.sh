#!/bin/bash
# UserPromptSubmit Hook: NCO 위임 규칙 강제 주입
# NCO 온라인 시 항상 주입 — 심각도에 따라 분량만 조절
# (단순 조회라도 기준선 규칙은 항상 표시)

INPUT=$(cat)

# NCO 온라인 확인
NCO_HEALTH=$(curl -s --connect-timeout 1 --max-time 2 "http://localhost:6200/health" 2>/dev/null)
[ -z "$NCO_HEALTH" ] && exit 0

# 사용자 프롬프트 추출
PROMPT_TEXT=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('userMessage', '')[:300])
except:
    pass
" 2>/dev/null || echo "")

# 세션별 에이전트 사용 추적
NCO_SESSION_ID="${NCO_SESSION_ID:-$$}"
SESSION_TRACK="/tmp/nco-track-${NCO_SESSION_ID}.json"

DIRECT_EDITS=0
NCO_CALLS=0
if [ -f "$SESSION_TRACK" ]; then
    DIRECT_EDITS=$(python3 -c "import json; d=json.load(open('$SESSION_TRACK')); print(d.get('direct_edits',0))" 2>/dev/null || echo 0)
    NCO_CALLS=$(python3 -c "import json; d=json.load(open('$SESSION_TRACK')); print(d.get('nco_calls',0))" 2>/dev/null || echo 0)
fi

# 변경 파일 수 (baseline 이후만)
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
BASELINE_F="/tmp/nco-baseline-${NCO_SESSION_ID}-files"
if [ -f "$BASELINE_F" ]; then
    CHANGED_COUNT=$(git -C "$PROJECT_DIR" diff --name-only 2>/dev/null | sort -u | comm -23 - <(sort -u "$BASELINE_F") | wc -l | tr -d ' ')
else
    CHANGED_COUNT=$(git -C "$PROJECT_DIR" diff --name-only 2>/dev/null | wc -l | tr -d ' ')
fi

# 규칙 주입 레벨 결정 — critical만 주입 (warn/remind는 CLAUDE.md와 중복, 토큰 낭비)
RULE_LEVEL="baseline"
if [ "$CHANGED_COUNT" -ge 5 ] && [ "$NCO_CALLS" -eq 0 ]; then
    RULE_LEVEL="critical"
elif [ "$DIRECT_EDITS" -ge 3 ] && [ "$NCO_CALLS" -eq 0 ]; then
    RULE_LEVEL="warn"
fi
# remind 레벨 제거 — CLAUDE.md에 동일 내용 존재, 중복 주입 불필요

# baseline/remind면 주입 없이 종료
[ "$RULE_LEVEL" = "baseline" ] && exit 0

# critical/warn은 세션당 최대 3회로 제한 (매 프롬프트 반복 방지)
INJECT_COUNT_FILE="/tmp/nco-rules-inject-count-${NCO_SESSION_ID}"
INJECT_COUNT=0
[ -f "$INJECT_COUNT_FILE" ] && INJECT_COUNT=$(cat "$INJECT_COUNT_FILE" 2>/dev/null || echo 0)
[ "$INJECT_COUNT" -ge 3 ] && exit 0
echo $((INJECT_COUNT + 1)) > "$INJECT_COUNT_FILE"

python3 - <<PYEOF
import json, sys

level = "$RULE_LEVEL"
changed = int("$CHANGED_COUNT" or 0)
direct = int("$DIRECT_EDITS" or 0)
nco = int("$NCO_CALLS" or 0)

lines = ["[NCO 위임 규칙]"]

if level == "critical":
    lines.append(f"⛔ 경고: 변경 파일 {changed}개, NCO 에이전트 사용 0회")
    lines.append("→ 즉시 nco_commander 또는 nco_parallel 로 위임하라")
    lines.append("")
elif level == "warn":
    lines.append(f"⚠ 주의: 직접 편집 {direct}회, NCO 사용 0회")
    lines.append("→ 3파일 이상 작업은 nco_parallel([codex, cursor-agent]) 사용 필수")
    lines.append("")
elif level == "remind":
    lines.append(f"→ 변경 파일 {changed}개 — 3-4개는 parallel, 5+는 commander")
    lines.append("")

if level != "baseline":
    lines += [
        "위임 기준: 1-2파일→직접 | 3-4파일→nco_parallel | 5+→nco_commander | 버그→codex+ollama",
    ]

# Agent 도구 위반 확인
import os
agent_violations = 0
track_file = f'/tmp/nco-track-{os.environ.get("NCO_SESSION_ID", str(os.getpid()))}.json'
try:
    import json as _json
    _td = _json.load(open(track_file))
    agent_violations = _td.get('agent_violations', 0)
except: pass

if agent_violations > 0:
    lines += [
        "",
        f"⛔ Agent 도구 위반: {agent_violations}회 — Claude Code Agent는 NCO 대체재가 아님!",
        "  → /nco-task, /nco-team, /nco-mesh send 만 사용할 것",
    ]

if level != "baseline":
    lines += [
        "",
        "Opus 규칙: 설계·지휘·감독만 수행, 모든 구현은 NCO 도구로 위임",
        "  → /nco-task <agent> <prompt> | /nco-team <prompt> | /nco-mesh send @<id> [TASK]",
        "  → Agent(general-purpose) 사용 금지 — PreToolUse 훅이 차단함",
        "결과는 반드시 검토 후 전달 (그대로 패스 금지)",
    ]

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": "\n".join(lines)
    }
}))
PYEOF

exit 0
