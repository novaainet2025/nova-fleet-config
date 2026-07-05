#!/bin/bash
# Stop Hook — NCO 세션 보고서
# NCO 사용률 + 완료 단계 + 미완료 단계 → systemMessage로 다음 세션 컨텍스트 제공

# ── 세션 ID ──────────────────────────────────────────────────
_SID="${NCO_SESSION_ID:-}"
if [ -z "$_SID" ]; then
  _CK=$$
  for _i in 1 2 3 4 5; do
    _CK=$(ps -o ppid= -p "$_CK" 2>/dev/null | tr -d ' ')
    [ -z "$_CK" ] && break
    ps -o comm= -p "$_CK" 2>/dev/null | grep -qE '^(claude|node)$' && { _SID="$_CK"; break; }
  done
  _SID="${_SID:-$$}"
fi

TRACK="/tmp/nco-track-${_SID}.json"
STAGE="/tmp/nco-stages-${_SID}.json"

# ── 통계 로드 ─────────────────────────────────────────────────
NCO_CALLS=0; DIRECT=0; AGENT_VIOL=0; TASK_TYPE="unknown"
if [ -f "$TRACK" ]; then
  read -r NCO_CALLS DIRECT AGENT_VIOL TASK_TYPE <<< "$(python3 -c "
import json
try:
    d=json.load(open('$TRACK'))
    print(d.get('nco_calls',0), d.get('direct_edits',0), d.get('agent_violations',0),
          d.get('task_type','unknown'))
except: print('0 0 0 unknown')
" 2>/dev/null)"
fi
TOTAL=$((NCO_CALLS + DIRECT))
PCT=0; [ "$TOTAL" -gt 0 ] && PCT=$((NCO_CALLS * 100 / TOTAL))

# 의미있는 세션인지 확인 (최소 2회 이상 도구 사용)
[ "$TOTAL" -lt 2 ] && exit 0

# ── 단계 로드 ─────────────────────────────────────────────────
STAGES_JSON="{}"
[ -f "$STAGE" ] && STAGES_JSON=$(cat "$STAGE" 2>/dev/null || echo "{}")

# ── 노이즈 억제: 워크플로우 상태(task_type+stages)가 지난 출력과 동일하면 재출력 생략 ──
# 매 턴 동일 리포트 반복(사용자 지적)을 막는다. 진전(단계 완료/타입 변경)이 있을 때만 출력.
_RPT_STATE="/tmp/nco-report-state-${_SID}"
_CUR_STATE=$(printf '%s|%s' "$TASK_TYPE" "$STAGES_JSON" | (md5 2>/dev/null || md5sum 2>/dev/null | cut -d' ' -f1))
if [ -f "$_RPT_STATE" ] && [ "$(cat "$_RPT_STATE" 2>/dev/null)" = "$_CUR_STATE" ]; then
    exit 0   # 상태 변화 없음 → 리포트 재출력 생략
fi
printf '%s' "$_CUR_STATE" > "$_RPT_STATE" 2>/dev/null

python3 - << PYEOF
import json, sys

nco = $NCO_CALLS
direct = $DIRECT
total = $TOTAL
pct = $PCT
agent_viol = $AGENT_VIOL
task_type = "$TASK_TYPE"

try:
    stages = json.loads("""$STAGES_JSON""")
except:
    stages = {}

stage_labels = {
    "discussion":     "토론/설계",
    "design":         "설계 위임",
    "implementation": "구현 위임",
    "review":         "코드 리뷰",
    "gap_analysis":   "Gap 분석",
    "verification":   "검증",
}

done   = [k for k, v in stages.items() if v]
missed = [k for k, v in stages.items() if not v]

# 진실 보고 게이트: new_feature에서 verification 미완료 시 경고 선행
unverified_warning = (
    task_type == "new_feature" and
    not stages.get("verification", False) and
    total >= 3
)

lines = []
if unverified_warning:
    lines.append("⚠️  [미검증 경고] 신규 기능 작업이 ollama 검증 없이 종료됩니다.")
    lines.append("   → 다음 세션 시작 시 반드시: /nco-task ollama '검증: [구현 내용]'")
    lines.append("")
lines.append("[NCO 세션 보고서]")

# NCO 사용률 바
bar = "█" * (pct // 10) + "░" * (10 - pct // 10)
status_icon = "✅" if pct >= 80 else ("⚠️" if pct >= 50 else "❌")
lines.append(f"{status_icon} NCO 사용률: {bar} {pct}%  (NCO:{nco}회 / 직접:{direct}회)")

if agent_viol > 0:
    lines.append(f"⛔ Agent 도구 위반: {agent_viol}회")

lines.append("")
lines.append("── 완료된 워크플로우 단계 ──")
if done:
    for k in done:
        lines.append(f"  ✅ {stage_labels.get(k, k)}")
else:
    lines.append("  (없음)")

lines.append("")
lines.append("── 미완료 단계 (다음 세션 권장) ──")
if missed:
    nco_cmds = {
        "discussion":     "/nco-discussion | /nco-task opencode '설계: ...'",
        "design":         "/nco-task opencode '아키텍처: ...'",
        "implementation": "/nco-task codex | /nco-team | /nco-parallel",
        "review":         "/nco-task cursor-agent '코드 리뷰: ...'",
        "gap_analysis":   "/nco-gap | /nco-task ollama 'Gap 분석: ...'",
        "verification":   "/nco-task ollama '검증: ...'",
    }
    for k in missed:
        lines.append(f"  ⬜ {stage_labels.get(k, k)}  →  {nco_cmds.get(k,'')}")
else:
    lines.append("  ✅ 모든 단계 완료!")

if pct < 80 and total >= 3:
    lines.append("")
    lines.append(f"💡 다음 세션 목표: NCO {80 - pct}% 더 사용해야 80% 달성")
    lines.append("   우선 위임: /nco-task codex | /nco-team | /nco-parallel")

print(json.dumps({"systemMessage": "\n".join(lines)}))
PYEOF
exit 0
