Mesh Heartbeat 전송 — 현재 세션 상태를 NCO Mesh에 등록합니다 (다른 CLI 세션에서 내 존재가 보입니다).

# 활성 세션 수를 확인하여 workMode 자동 결정 후 heartbeat 전송

python3 - <<'PYEOF'
import json, urllib.request, os

# 활성 세션 수 확인
active_sessions = 0
try:
    with urllib.request.urlopen("http://localhost:6200/api/mesh/sessions", timeout=3) as r:
        data = json.loads(r.read())
        active_sessions = data.get("count", 0)
except Exception:
    pass

wm = "mesh" if active_sessions > 1 else "solo"
st = "discussing" if active_sessions > 1 else "coding"
pid = os.getpid()

payload = json.dumps({
    "sessionId": str(pid),
    "agentId": "claude-code",
    "pid": pid,
    "workMode": wm,
    "status": st,
    "currentWork": "Claude Code 작업 중",
    "currentFiles": [],
    "branch": "master"
}).encode()

req = urllib.request.Request(
    "http://localhost:6200/api/mesh/heartbeat",
    data=payload,
    headers={"Content-Type": "application/json"},
    method="POST"
)
try:
    with urllib.request.urlopen(req, timeout=3) as r:
        result = json.loads(r.read())
        msgs = result.get("messages", [])
        conflicts = result.get("conflicts", [])
        print(f"✓ Heartbeat 전송 완료")
        print(f"  workMode : {wm}  |  status : {st}")
        print(f"  활성 세션 : {active_sessions}개")
        if msgs:
            print(f"\n  [메시지 {len(msgs)}건]")
            for m in msgs:
                print(f"    • {m.get('fromAgent','?')}: {m.get('content','')}")
        if conflicts:
            print(f"\n  [충돌 감지 {len(conflicts)}건]")
            for c in conflicts:
                print(f"    ⚠ {c}")
except Exception as e:
    print(f"✗ 전송 실패: {e}")
    print("  NCO 백엔드가 실행 중인지 확인하세요 (/nco-start)")
PYEOF
