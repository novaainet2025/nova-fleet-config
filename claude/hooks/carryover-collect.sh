#!/usr/bin/env bash
# carryover-collect.sh — Stop 시 미검증항목을 이월 원장에 등록 (Fix C)
# stdin(Stop payload)의 transcript_path에서 최종 응답의 [미검증항목](없음 제외)을 추출해 add.
INPUT=$(cat 2>/dev/null)
CO="$HOME/.claude/hooks/carryover.sh"
[ -x "$CO" ] || exit 0
TP=$(printf '%s' "$INPUT" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("transcript_path",""))
except: print("")' 2>/dev/null)
[ -z "$TP" ] && TP="${NCO_TRANSCRIPT:-}"
[ -f "$TP" ] || exit 0

# 최종 assistant 응답에서 [미검증항목] 추출 (없음/N/A 제외)
printf '%s' "$TP" | python3 - "$TP" <<'PY' | while IFS= read -r item; do
import sys,json,re
path=sys.argv[1]
chunks=[]
for ln in open(path,encoding="utf-8",errors="ignore").read().splitlines()[-4000:]:
    try: d=json.loads(ln)
    except: continue
    if d.get("type")=="assistant":
        c=(d.get("message") or {}).get("content")
        if isinstance(c,list):
            for b in c:
                if isinstance(b,dict) and b.get("type")=="text": chunks.append(b.get("text",""))
final="\n".join(chunks[-3:])  # 최근 몇 턴
items=re.findall(r'\[미검증항목\]\s*([^\n]{4,120})', final)
out=[]
for it in items:
    it=it.strip().strip('()')
    if not it: continue
    if re.match(r'^(없음|N/?A|none|-)$', it, re.I): continue
    out.append(it)
# 중복 제거
seen=set()
for it in out:
    k=it[:60]
    if k in seen: continue
    seen.add(k); print(it[:120])
PY
    [ -n "$item" ] && bash "$CO" add "$item" >/dev/null 2>&1
done
exit 0
