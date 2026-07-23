#!/usr/bin/env bash
# carryover-collect.sh — Stop 시 미검증항목을 이월 원장에 등록 (Fix C, 세션스코프)
# stdin(Stop payload)의 session_id로 스코프. transcript의 최종 [미검증항목](없음 제외) 추출.
# supersede로 이전 auto 항목 정리 후 현재분만 재등록 → 과잉 누적 방지.
INPUT=$(cat 2>/dev/null)
CO="$HOME/.claude/hooks/carryover.sh"
[ -x "$CO" ] || exit 0
SID=$(printf '%s' "$INPUT" | python3 -c 'import sys,json
try: d=json.load(sys.stdin); print(d.get("session_id") or "")
except: print("")' 2>/dev/null)
TP=$(printf '%s' "$INPUT" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("transcript_path",""))
except: print("")' 2>/dev/null)
[ -z "$TP" ] && TP="${NCO_TRANSCRIPT:-}"
[ -z "$SID" ] && SID=$(basename "$TP" .jsonl 2>/dev/null)
[ -f "$TP" ] || exit 0
[ -z "$SID" ] && exit 0

# 이 세션의 이전 auto 항목 정리(과잉 누적 방지)
CO_SID="$SID" bash "$CO" supersede >/dev/null 2>&1

TP="$TP" python3 <<'PY' | while IFS= read -r item; do
import os,json,re
path=os.environ["TP"]
chunks=[]
for ln in open(path,encoding="utf-8",errors="ignore").read().splitlines()[-4000:]:
    try: d=json.loads(ln)
    except: continue
    if d.get("type")=="assistant":
        c=(d.get("message") or {}).get("content")
        if isinstance(c,list):
            for b in c:
                if isinstance(b,dict) and b.get("type")=="text": chunks.append(b.get("text",""))
final="\n".join(chunks[-3:])
items=re.findall(r'\[미검증항목\]\s*([^\n]{4,120})', final)
seen=set()
for it in items:
    it=it.strip().strip('()')
    if not it or re.match(r'^(없음|N/?A|none|-)$', it, re.I): continue
    k=it[:60]
    if k in seen: continue
    seen.add(k); print(it[:120])
PY
    [ -n "$item" ] && CO_SID="$SID" CO_SRC=auto bash "$CO" add "$item" >/dev/null 2>&1
done
exit 0
