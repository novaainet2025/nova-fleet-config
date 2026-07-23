#!/usr/bin/env bash
# loop-lesson.sh — 루프 엔진 자가학습 캐시 (Task 3)
# 반복 실패/교훈을 파일에 축적하고, 동일 에러 N회 감지 시 우회 힌트를 표면화한다.
# 프로바이더 비의존 — 어떤 에이전트든 shell로 호출.
#
# 사용:
#   loop-lesson.sh add   "<key>" "<lesson text>"   # 교훈 1건 기록 (key=에러/작업 지문)
#   loop-lesson.sh count "<key>"                    # 해당 key 누적 횟수 (3회 감지 룰용)
#   loop-lesson.sh recent [N]                       # 최근 N건(기본5) 출력
#   loop-lesson.sh inject                           # UserPromptSubmit용 컨텍스트 주입(최근 3건)
#   loop-lesson.sh workaround "<key>"               # key에 대해 3회+ 반복 시 우회 힌트

set -u
DIR="$HOME/.claude/.loop-lessons"
LOG="$DIR/lessons.jsonl"
mkdir -p "$DIR"; [ -f "$LOG" ] || : > "$LOG"

# 결정론적 타임스탬프 회피 규칙 준수: date는 셸에서 직접 호출(스크립트 실행 시점)
_now(){ date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown"; }

cmd="${1:-}"; shift 2>/dev/null || true
case "$cmd" in
  add)
    key="${1:-}"; text="${2:-}"
    [ -z "$key" ] && { echo "usage: add <key> <lesson>" >&2; exit 1; }
    python3 - "$key" "$text" "$(_now)" "$LOG" <<'PY'
import json,sys
key,text,ts,log=sys.argv[1:5]
row={"ts":ts,"key":key,"lesson":text}
with open(log,"a",encoding="utf-8") as f: f.write(json.dumps(row,ensure_ascii=False)+"\n")
print(f"[loop-lesson] 기록: {key}")
PY
    ;;
  count)
    key="${1:-}"
    python3 - "$key" "$LOG" <<'PY'
import json,sys
key,log=sys.argv[1:3]; n=0
for line in open(log,encoding="utf-8"):
    try:
        if json.loads(line).get("key")==key: n+=1
    except: pass
print(n)
PY
    ;;
  recent)
    n="${1:-5}"
    python3 - "$n" "$LOG" <<'PY'
import json,sys
n=int(sys.argv[1]); log=sys.argv[2]
rows=[json.loads(l) for l in open(log,encoding="utf-8") if l.strip()]
for r in rows[-n:]:
    print(f"  • [{r.get('key')}] {r.get('lesson')}  ({r.get('ts')})")
PY
    ;;
  inject)
    # 최근 3건이 있으면만 주입 (조용히)
    cnt=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
    [ "${cnt:-0}" -eq 0 ] && exit 0
    echo "[LOOP-LESSONS] 최근 자가학습 교훈 (동일 실패 반복 방지):"
    python3 - "$LOG" <<'PY'
import json,sys
log=sys.argv[1]
rows=[json.loads(l) for l in open(log,encoding="utf-8") if l.strip()]
for r in rows[-3:]:
    print(f"  • {r.get('key')}: {r.get('lesson')}")
PY
    ;;
  workaround)
    key="${1:-}"
    c=$(bash "$0" count "$key")
    if [ "${c:-0}" -ge 3 ]; then
      echo "⚠️ [자가학습] '$key' ${c}회 반복 실패 — 이전 접근 재시도 금지. 우회로 탐색 필요."
      exit 3
    fi
    exit 0
    ;;
  *) echo "usage: loop-lesson.sh {add|count|recent|inject|workaround}" >&2; exit 1 ;;
esac
