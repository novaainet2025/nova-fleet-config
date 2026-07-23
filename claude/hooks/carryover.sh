#!/usr/bin/env bash
# carryover.sh — 미해결 이월 원장 (Fix C + 2026-07-23 세션스코프 수정)
# 미검증항목·미완이 세션을 넘어 사라지지 않게 추적. verify/사용자승인으로만 close.
# ★동시세션 격리: 항목에 sid 태그. inject/list/count는 기본 현재 세션(CO_SID)만 —
#   feedback_hook_shared_state_concurrency(공유상태 SID스코프 필수) 준수.
#
#   CO_SID=<sid> CO_SRC=auto|manual carryover.sh add "<item>" [key]
#   CO_SID=<sid> carryover.sh inject | list | count      # 현재 세션만
#   carryover.sh list --all                               # 전 세션(sid 표기)
#   carryover.sh close <key> "<근거>"                     # 근거必
#   CO_SID=<sid> carryover.sh supersede                   # 그 세션의 auto 항목 일괄 close(과잉수집 방지)

set -u
DIR="$HOME/.claude/.carryover"; LOG="$DIR/open-items.jsonl"
mkdir -p "$DIR"; [ -f "$LOG" ] || : > "$LOG"
_now(){ date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown; }
SID="${CO_SID:-}"; SRC="${CO_SRC:-manual}"
cmd="${1:-}"; shift 2>/dev/null || true

case "$cmd" in
  add)
    item="${1:-}"; key="${2:-}"
    [ -z "$item" ] && exit 0
    ITEM="$item" KEY="$key" SID="$SID" SRC="$SRC" TS="$(_now)" LOG="$LOG" python3 <<'PY'
import os,json,hashlib
item=os.environ["ITEM"]; key=os.environ["KEY"]; sid=os.environ["SID"]; src=os.environ["SRC"]; ts=os.environ["TS"]; log=os.environ["LOG"]
key=key or ("co-"+hashlib.md5((sid+item).encode()).hexdigest()[:8])
seen=set()
for l in open(log,encoding="utf-8"):
    try:
        d=json.loads(l)
        if d.get("status")=="open" and d.get("sid")==sid: seen.add(d.get("key"))
    except: pass
if key in seen: raise SystemExit(0)
with open(log,"a",encoding="utf-8") as f:
    f.write(json.dumps({"ts":ts,"key":key,"item":item,"status":"open","sid":sid,"src":src},ensure_ascii=False)+"\n")
print(f"[carryover] 이월({src},sid={sid[:8]}): {key}")
PY
    ;;
  supersede)
    # 현재 세션의 auto 항목만 close (다음 재수집 전 정리 → 과잉 누적 방지)
    SID="$SID" TS="$(_now)" LOG="$LOG" python3 <<'PY'
import os,json
sid=os.environ["SID"]; ts=os.environ["TS"]; log=os.environ["LOG"]
rows=[]
for l in open(log,encoding="utf-8"):
    try: d=json.loads(l)
    except: continue
    if d.get("status")=="open" and d.get("sid")==sid and d.get("src")=="auto":
        d["status"]="closed"; d["closed_ts"]=ts; d["close_reason"]="superseded(재수집)"
    rows.append(d)
open(log,"w",encoding="utf-8").write("\n".join(json.dumps(r,ensure_ascii=False) for r in rows)+("\n" if rows else ""))
PY
    ;;
  close)
    key="${1:-}"; reason="${2:-}"
    [ -z "$key" ] && { echo "usage: close <key> <근거>" >&2; exit 1; }
    [ -z "$reason" ] && { echo "❌ close에는 근거(verify exit0/사용자승인) 필수 — 조용한 종료 금지" >&2; exit 2; }
    KEY="$key" REASON="$reason" TS="$(_now)" LOG="$LOG" python3 <<'PY'
import os,json
key=os.environ["KEY"]; reason=os.environ["REASON"]; ts=os.environ["TS"]; log=os.environ["LOG"]
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
    ALL=0; [ "${1:-}" = "--all" ] && ALL=1
    MODE="$cmd" SID="$SID" ALL="$ALL" LOG="$LOG" python3 <<'PY'
import os,json
mode=os.environ["MODE"]; sid=os.environ["SID"]; allf=os.environ["ALL"]=="1"; log=os.environ["LOG"]
opens=[]
for l in open(log,encoding="utf-8"):
    try:
        d=json.loads(l)
        if d.get("status")!="open": continue
        if not allf and d.get("sid","")!=sid: continue   # ★세션 스코프
        opens.append(d)
    except: pass
uniq={}
for d in opens: uniq[d.get("key")]=d
opens=list(uniq.values())
if mode=="count": print(len(opens)); raise SystemExit(0)
if not opens: raise SystemExit(0)
def ad(ts): return (ts or "")[:10]
if mode=="inject":
    print(f"[미해결 이월 {len(opens)}건 — verify/승인 전까지 종료 불가]")
    for d in opens[:5]: print(f"  ▢ {d.get('item')}  (key={d.get('key')}, {ad(d.get('ts'))})")
else:
    print(f"미해결 이월 {len(opens)}건{' [전세션]' if allf else ''}:")
    for d in opens:
        tag=f" sid={d.get('sid','')[:8]}" if allf else ""
        print(f"  ▢ [{d.get('key')}] {d.get('item')}  (등록 {ad(d.get('ts'))}{tag})")
PY
    ;;
  *) echo "usage: carryover.sh {add|list|close|inject|count|supersede} (CO_SID로 세션스코프)" >&2; exit 1 ;;
esac
