#!/usr/bin/env bash
# carryover.sh — 미해결 이월 원장 (Fix C: 자기개선 루프 닫기)
# 미검증항목·미완 목표가 세션을 넘어 사라지지 않게 추적. verify 또는 사용자 승인으로만 close.
#
#   carryover.sh add   "<item>" [key]     # 이월 항목 추가(내용해시 중복방지)
#   carryover.sh list                      # open 항목 (나이 포함)
#   carryover.sh close  <key> "<근거>"     # 닫기 (근거 필수 — verify exit0/사용자승인)
#   carryover.sh inject                    # UserPromptSubmit용: open 있으면 강제 표면화
#   carryover.sh count                     # open 개수

set -u
DIR="$HOME/.claude/.carryover"; LOG="$DIR/open-items.jsonl"
mkdir -p "$DIR"; [ -f "$LOG" ] || : > "$LOG"
_now(){ date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown; }
cmd="${1:-}"; shift 2>/dev/null || true

case "$cmd" in
  add)
    item="${1:-}"; key="${2:-}"
    [ -z "$item" ] && exit 0
    python3 - "$item" "$key" "$(_now)" "$LOG" <<'PY'
import sys,json,hashlib
item,key,ts,log=sys.argv[1:5]
key=key or ("co-"+hashlib.md5(item.encode()).hexdigest()[:8])
# 이미 open 동일 key 있으면 skip (중복방지)
seen=set()
for l in open(log,encoding="utf-8"):
    try:
        d=json.loads(l)
        if d.get("status")=="open": seen.add(d.get("key"))
    except: pass
if key in seen: sys.exit(0)
with open(log,"a",encoding="utf-8") as f:
    f.write(json.dumps({"ts":ts,"key":key,"item":item,"status":"open"},ensure_ascii=False)+"\n")
print(f"[carryover] 이월: {key}")
PY
    ;;
  close)
    key="${1:-}"; reason="${2:-}"
    [ -z "$key" ] && { echo "usage: close <key> <근거>" >&2; exit 1; }
    [ -z "$reason" ] && { echo "❌ close에는 근거(verify exit0/사용자승인) 필수 — 조용한 종료 금지" >&2; exit 2; }
    python3 - "$key" "$reason" "$(_now)" "$LOG" <<'PY'
import sys,json
key,reason,ts,log=sys.argv[1:4+1] if False else sys.argv[1:5]
rows=[]
for l in open(log,encoding="utf-8"):
    try: d=json.loads(l)
    except: continue
    if d.get("key")==key and d.get("status")=="open":
        d["status"]="closed"; d["closed_ts"]=ts; d["close_reason"]=reason
    rows.append(d)
open(log,"w",encoding="utf-8").write("\n".join(json.dumps(r,ensure_ascii=False) for r in rows)+("\n" if rows else ""))
print(f"[carryover] closed: {key} ({reason})")
PY
    ;;
  list|count|inject)
    python3 - "$cmd" "$LOG" <<'PY'
import sys,json,datetime
mode,log=sys.argv[1:3]
opens=[]
for l in open(log,encoding="utf-8"):
    try:
        d=json.loads(l)
        if d.get("status")=="open": opens.append(d)
    except: pass
# 최신 우선, key 중복 제거(가장 최근 것)
uniq={}
for d in opens: uniq[d.get("key")]=d
opens=list(uniq.values())
if mode=="count":
    print(len(opens)); sys.exit(0)
if not opens:
    sys.exit(0)
def age(ts):
    try:
        t=datetime.datetime.strptime(ts,"%Y-%m-%dT%H:%M:%SZ")
        # 결정론 회피: 나이는 로그상 순번으로 대체 표기 불가 → 날짜만
        return ts[:10]
    except: return "?"
if mode=="inject":
    print(f"[미해결 이월 {len(opens)}건 — verify/승인 전까지 종료 불가]")
    for d in opens[:5]:
        print(f"  ▢ {d.get('item')}  (key={d.get('key')}, {age(d.get('ts',''))})")
else:  # list
    print(f"미해결 이월 {len(opens)}건:")
    for d in opens:
        print(f"  ▢ [{d.get('key')}] {d.get('item')}  (등록 {age(d.get('ts',''))})")
PY
    ;;
  *) echo "usage: carryover.sh {add|list|close|inject|count}" >&2; exit 1 ;;
esac
