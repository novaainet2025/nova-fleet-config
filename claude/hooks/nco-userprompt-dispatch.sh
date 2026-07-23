#!/usr/bin/env bash
# nco-userprompt-dispatch.sh — UserPromptSubmit 순수 배너 주입기 통합 dispatcher
# 목적: 6개 배너 주입 훅을 1개 프로세스로 합쳐 subprocess 스폰 수 감소.
# 원칙: 차단(exit 2)하지 않는 주입 전용 훅만 포함. 기능/순서 민감 훅(task-classifier,
#       mesh-heartbeat, nco-context 등)은 settings.json에 standalone 유지.
# 정확성: 하위 훅이 JSON(hookSpecificOutput.additionalContext) 또는 평문을 출력해도
#         모두 파싱/추출해 **단일 유효 JSON**으로 병합 출력 (날 JSON 누출 방지).
# throttle: NCO_QUIET_BANNERS=1 이면 세션 첫 프롬프트 이후 장황 배너 억제.

INPUT=$(cat)
H="$HOME/.claude/hooks"

SID="${NCO_SESSION_ID:-$$}"
FLAG="/tmp/nco-ups-seen-${SID}"
FIRST=1; [ -f "$FLAG" ] && FIRST=0; : > "$FLAG"

# 실행할 하위 훅 목록 결정
HOOKS="improvement-inject.sh nco-collab-inject.sh obsidian-context-inject.sh"
if [ "${NCO_QUIET_BANNERS:-0}" != "1" ] || [ "$FIRST" = "1" ]; then
  HOOKS="$HOOKS nco-workflow-inject.sh user-prompt-nco-route.sh nco-rules-inject.sh"
fi

# 각 훅 stdout 수집 (구분자 \x1e)
OUT=""
for h in $HOOKS; do
  [ -f "$H/$h" ] || continue
  o=$(printf '%s' "$INPUT" | bash "$H/$h" 2>/dev/null)
  [ -n "$o" ] && OUT="${OUT}${o}"$'\x1e'
done
# 자가학습 교훈 (Task 3)
LL="$H/loop-lesson.sh"
if [ -x "$LL" ]; then
  o=$(bash "$LL" inject 2>/dev/null); [ -n "$o" ] && OUT="${OUT}${o}"$'\x1e'
fi
# 미해결 이월 강제 표면화 (Fix C) — verify/승인 전까지 안 사라짐. ★현재 세션만(동시세션 격리)
CO="$H/carryover.sh"
if [ -x "$CO" ]; then
  _cosid=$(printf '%s' "$INPUT" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("session_id") or "")
except: print("")' 2>/dev/null)
  o=$(CO_SID="$_cosid" bash "$CO" inject 2>/dev/null); [ -n "$o" ] && OUT="${OUT}${o}"$'\x1e'
fi

# 평문/JSON 혼합을 단일 JSON additionalContext로 병합
printf '%s' "$OUT" | python3 -c '
import sys,json
raw=sys.stdin.read()
parts=[p for p in raw.split("\x1e") if p.strip()]
merged=[]
for p in parts:
    s=p.strip()
    try:
        d=json.loads(s)
        ac=(d.get("hookSpecificOutput") or {}).get("additionalContext")
        merged.append(ac if ac else s)
    except Exception:
        merged.append(p.rstrip("\n"))
ctx="\n\n".join(merged)
if ctx.strip():
    print(json.dumps({"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":ctx}}, ensure_ascii=False))
'
exit 0
