#!/usr/bin/env bash
# trust-status.sh — 사용자용 단일 신뢰 확인 명령 (Fix D)
# 결정론적(LLM 없음). 모든 항목이 소스 파일을 인용 → 사용자가 직접 재확인 가능.
# 사용: bash ~/.claude/trust-status.sh [transcript_path]
#   인자 없으면 최근 transcript 자동탐지. 신뢰는 "말"이 아니라 여기 출력의 지상진실로 확인한다.

H="$HOME/.claude/hooks"
TP="${1:-}"
[ -z "$TP" ] && TP=$(ls -t "$HOME"/.claude/projects/*/*.jsonl 2>/dev/null | head -1)

echo "━━━━━━━━━━━━ 신뢰 상태 (trust-status) — 지상진실 ━━━━━━━━━━━━"

# ① 미해결 이월 (사라지지 않는 과제)
echo "▶ ① 미해결 이월  [소스: ~/.claude/.carryover/open-items.jsonl]"
if [ -x "$H/carryover.sh" ]; then
  OUT=$(bash "$H/carryover.sh" list 2>/dev/null)
  [ -n "$OUT" ] && echo "$OUT" | sed 's/^/   /' || echo "   (없음 — 모든 과제 close됨)"
else echo "   (carryover 미설치)"; fi

# ② 이번 세션 목표 · 정직Gap (증거 있는 것만 해결로 카운트)
echo "▶ ② 세션 목표 · 정직Gap  [소스: session-goal-check.sh + transcript]"
if [ -n "$TP" ] && [ -f "$TP" ] && [ -x "$H/session-goal-check.sh" ]; then
  J=$(bash "$H/session-goal-check.sh" "$TP" 2>/dev/null | tail -1)
  SGC_JSON="$J" python3 - <<'PY'
import os,json
try: d=json.loads(os.environ.get("SGC_JSON","") or "{}")
except: d={}
if not d: print("   (판정 불가)")
else:
    g=d.get("gap"); hg=d.get("honest_gap"); er=d.get("evidence_resolved"); tot=d.get("total",0)
    print(f"   낙관 달성률 {g}%  vs  \U0001F50E정직Gap {hg}% (증거보유 {er}/{tot})")
    if g is not None and hg is not None and g-hg>=20:
        print(f"   ⚠️ 격차 {g-hg}%p — 미검증 완료주장이 있다는 신호 (믿지 말 것)")
    for i,x in enumerate(d.get("goals",[]),1):
        ev="✔증거" if x.get("evidence") else "✖무증거"
        print(f"     {i}. {x.get('status')} [{ev}] {x.get('summary','')[:40]}")
    print(f"   게이트차단 {d.get('gate_blocks',0)}회 · 미검증항목 {d.get('unverified',0)}건 · 사용자지적 {d.get('pushback',0)}회")
PY
  echo "   (transcript: $TP)"
else echo "   (transcript 없음 — 인자로 경로 지정 가능)"; fi

# ③ 최근 자동포착 교훈
echo "▶ ③ 최근 자동포착 교훈  [소스: ~/.claude/.loop-lessons/lessons.jsonl]"
if [ -x "$H/loop-lesson.sh" ]; then
  OUT=$(bash "$H/loop-lesson.sh" recent 3 2>/dev/null)
  [ -n "$OUT" ] && echo "$OUT" || echo "   (없음)"
else echo "   (loop-lesson 미설치)"; fi

# ④ 거짓보고 게이트 누적
echo "▶ ④ 거짓보고 게이트 누적  [소스: ~/.claude/.false-report-count]"
CNT=$(cat "$HOME/.claude/.false-report-count" 2>/dev/null || echo 0)
echo "   누적 차단 ${CNT}회 (게이트가 실제 작동 중이라는 증거 — 0이면 이번 세션 위반 없음)"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "재확인: 위 [소스] 파일을 cat 하면 동일 데이터를 직접 볼 수 있음 (조작 불가)"
