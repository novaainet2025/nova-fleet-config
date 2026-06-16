# NCO 사용 대시보드

NCO 에이전트 사용 현황, 호출 통계, 성능 지표를 표시한다.

다음 bash 명령을 **즉시 Bash 도구로 실행**하라 (출력만 하지 말고):

```bash
python3 <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone

PERF_DIR = os.path.expanduser("~/.claude/nco-perf")
SCORES_FILE = os.path.join(PERF_DIR, "scores.json")
USAGE_LOG   = os.path.join(PERF_DIR, "usage.jsonl")

# ── 데이터 로드 ──────────────────────────────────────────
try:
    db = json.load(open(SCORES_FILE))
except:
    db = {"providers": {}, "history": []}

# JSONL 로그 로드
log_entries = []
if os.path.exists(USAGE_LOG):
    for line in open(USAGE_LOG):
        try: log_entries.append(json.loads(line))
        except: pass

providers = db.get("providers", {})
history   = db.get("history",   [])

# ── 세션별 /tmp NCO track 파일에서 현재 세션 통계 ────────
session_stats = {}
for f in os.listdir("/tmp"):
    if f.startswith("nco-track-") and f.endswith(".json"):
        try:
            d = json.load(open(f"/tmp/{f}"))
            sid = f.replace("nco-track-","").replace(".json","")
            session_stats[sid] = {
                "nco_calls":  d.get("nco_calls", 0),
                "direct":     d.get("direct_edits", 0),
                "violations": d.get("agent_violations", 0),
                "task_type":  d.get("task_type",""),
            }
        except: pass

# ── 출력 ─────────────────────────────────────────────────
print("╔══════════════════════════════════════════════════════════════╗")
print("║            NCO 에이전트 사용 대시보드                        ║")
print("╚══════════════════════════════════════════════════════════════╝")

# 1. 에이전트별 통계
print("\n📊 에이전트별 누적 통계 (scores.json)")
print(f"{'에이전트':<16} {'총호출':>6} {'성공':>6} {'실패':>6} {'성공률':>7} {'평균응답':>8}")
print("─" * 60)
sorted_prov = sorted(providers.items(), key=lambda x: x[1].get("total_calls", 0), reverse=True)
for ai, p in sorted_prov:
    total = p.get("total_calls", 0)
    succ  = p.get("successes",   0)
    fail  = p.get("failures",    0)
    rate  = f"{succ/total*100:.1f}%" if total else "N/A"
    avg_r = f"{p.get('total_response_chars',0)//max(succ,1):,}" if succ else "0"
    print(f"  {ai:<14} {total:>6} {succ:>6} {fail:>6} {rate:>7} {avg_r:>8}자")

if not providers:
    print("  (아직 NCO 호출 기록 없음)")

# 2. 세션별 현황
if session_stats:
    print("\n\n🖥️  활성 세션 NCO 사용률")
    print(f"{'세션ID':<12} {'NCO':>5} {'직접':>5} {'위반':>5} {'사용률':>8} {'작업유형'}")
    print("─" * 55)
    for sid, s in session_stats.items():
        nco  = s["nco_calls"]
        direct = s["direct"]
        total = nco + direct
        rate = f"{nco/total*100:.0f}%" if total else "0%"
        bar  = "█" * (int(nco/max(total,1)*10)) + "░" * (10-int(nco/max(total,1)*10))
        print(f"  {sid:<10} {nco:>5} {direct:>5} {s['violations']:>5} {rate:>6}  {bar}  {s['task_type']}")

# 3. 최근 호출 20건 (JSONL 또는 history)
recent = log_entries[-20:] if log_entries else history[-20:]
if recent:
    print("\n\n📋 최근 호출 기록")
    print(f"{'시간':>8}  {'에이전트':<14} {'작업유형':<14} {'결과':>6} {'응답길이':>8}")
    print("─" * 60)
    for e in reversed(recent):
        ts   = e.get("ts","")[-8:][:5] if e.get("ts") else "--"
        ais  = ",".join(e.get("ai", ["?"]))[:13]
        tt   = e.get("task_type","?")[:13]
        ok   = "❌FAIL" if e.get("failed") else "✅ OK "
        rlen = e.get("resp_len", 0)
        print(f"  {ts:>5}  {ais:<14} {tt:<14} {ok}  {rlen:>7}자")

# 4. 응답 미리보기 (최근 3건)
recent_with_preview = [e for e in reversed(recent) if e.get("resp_preview")][:3]
if recent_with_preview:
    print("\n\n💬 최근 응답 미리보기")
    print("─" * 60)
    for i, e in enumerate(recent_with_preview, 1):
        ais = ",".join(e.get("ai",["?"]))
        ts  = e.get("ts","")
        preview = e.get("resp_preview","")[:200].replace("\n"," ")
        print(f"\n[{i}] {ais} @ {ts}")
        print(f"    {preview}...")

# 5. JSONL 전체 통계
if log_entries:
    total_log = len(log_entries)
    succ_log  = sum(1 for e in log_entries if not e.get("failed"))
    agents_log = {}
    for e in log_entries:
        for a in e.get("ai", []):
            agents_log[a] = agents_log.get(a, 0) + 1
    top_agent = max(agents_log, key=agents_log.get) if agents_log else "없음"
    print(f"\n\n📈 전체 세션 누적 (usage.jsonl)")
    print(f"  총 호출: {total_log}회 | 성공: {succ_log}회 | 성공률: {succ_log/total_log*100:.1f}%")
    print(f"  가장 많이 사용된 AI: {top_agent} ({agents_log.get(top_agent,0)}회)")
    print(f"  로그 파일: {USAGE_LOG}")

print("\n" + "═" * 62)
print(f"  scores.json: {SCORES_FILE}")
print(f"  usage.jsonl: {USAGE_LOG}  ({len(log_entries)}건)")
print("═" * 62)
PYEOF
```
