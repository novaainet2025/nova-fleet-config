# Nova-AX Inter-Session Team — 팀 세션 운영 커맨드
# [CLAUDE INSTRUCTION]
# 이 커맨드는 inter-session team.json 기반 팀 운영을 담당한다.
# RULE 1: 사용자 입력 필요 시 → question: <coordinator> 로만 전송. 사용자에게 직접 묻지 않는다.
# RULE 2: coordinator = NCO_NAME이 claude-1인 세션 (사용자가 제어하는 세션).
# RULE 3: 모든 작업은 자율 실행 후 done:/status: 로 coordinator에게 보고.

# 사용법:
#   /nco-team-session role=<역할> [tags=<tag1,tag2>]   — 팀 등록 (역할/능력 선언)
#   /nco-team-session list                              — 팀 멤버 + 태스크 현황
#   /nco-team-session task <내용> [tags=<태그>] [deadline=<초>]  — 태스크 생성 + 자동 위임
#   /nco-team-session done <task-id> <결과요약>         — 태스크 완료 보고
#   /nco-team-session status                            — 내 세션 현황
#   /nco-team-session deregister                        — 팀에서 탈퇴

BIN="{{HOME}}/.claude/plugins/cache/inter-session/inter-session/0.1.2/skills/inter-session/bin"
TEAM_JSON="$HOME/.claude/data/inter-session/team.json"
ARGS="${ARGUMENTS:-}"
CMD=$(echo "$ARGS" | awk '{print $1}')

# ── 공통 헬퍼: 현재 세션 이름 조회 ──
_get_my_name() {
  python3 - << 'PYEOF'
import sys, os, json, subprocess
from pathlib import Path

sys.path.insert(0, '{{HOME}}/.claude/plugins/cache/inter-session/inter-session/0.1.2/skills/inter-session/bin')
import shared

# 1) 환경변수 우선
nco_name = os.environ.get("NCO_NAME", "")

# 2) PPID 체인으로 session 파일 탐색
def ppid_of(pid):
    try:
        out = subprocess.check_output(["ps", "-p", str(pid), "-o", "ppid="],
                                      stderr=subprocess.DEVNULL).decode().strip()
        return int(out) if out else None
    except Exception:
        return None

def find_session_name():
    pid = os.getpid()
    seen = set()
    while pid and pid not in seen:
        seen.add(pid)
        path = shared.client_session_path(pid)
        if path.exists():
            try:
                d = json.loads(path.read_text())
                lp = d.get("listener_pid", 0)
                r = subprocess.run(["ps", "-p", str(lp)], capture_output=True)
                if r.returncode == 0:
                    return d.get("name", "")
            except Exception:
                pass
        pp = ppid_of(pid)
        if pp is None:
            break
        pid = pp
    return ""

name = find_session_name() or nco_name
if name:
    print(name)
PYEOF
}

# ── 공통 헬퍼: coordinator 이름 조회 ──
_get_coordinator() {
  python3 - "$TEAM_JSON" << 'PYEOF'
import sys, json
from pathlib import Path
path = Path(sys.argv[1])
if path.exists():
    try:
        d = json.loads(path.read_text())
        print(d.get("coordinator", "claude-1"))
    except Exception:
        print("claude-1")
else:
    print("claude-1")
PYEOF
}

# ── 공통 헬퍼: send.py PPID override 자동 탐지 ──
_get_ppid_override() {
  python3 - << 'PYEOF'
import os, subprocess, json
from pathlib import Path
import sys
sys.path.insert(0, '{{HOME}}/.claude/plugins/cache/inter-session/inter-session/0.1.2/skills/inter-session/bin')
import shared

def ppid_of(pid):
    try:
        out = subprocess.check_output(["ps", "-p", str(pid), "-o", "ppid="],
                                      stderr=subprocess.DEVNULL).decode().strip()
        return int(out) if out else None
    except Exception:
        return None

pid = os.getpid()
seen = set()
while pid and pid not in seen:
    seen.add(pid)
    path = shared.client_session_path(pid)
    if path.exists():
        try:
            d = json.loads(path.read_text())
            lp = d.get("listener_pid", 0)
            r = subprocess.run(["ps", "-p", str(lp)], capture_output=True)
            if r.returncode == 0:
                print(pid)
                sys.exit(0)
        except Exception:
            pass
    pp = ppid_of(pid)
    if pp is None:
        break
    pid = pp
PYEOF
}

# ── 공통 헬퍼: team.json 전송 (optimistic locking) ──
_send_msg() {
  local TO="$1"
  local TEXT="$2"
  local PPID_OVERRIDE
  PPID_OVERRIDE=$(_get_ppid_override)
  if [ -n "$PPID_OVERRIDE" ]; then
    INTER_SESSION_PPID_OVERRIDE="$PPID_OVERRIDE" python3 "$BIN/send.py" --to "$TO" --text "$TEXT" 2>&1
  else
    python3 "$BIN/send.py" --to "$TO" --text "$TEXT" 2>&1
  fi
}

case "$CMD" in

  role=*)
    # role=<역할> [tags=<tag1,tag2>]
    ROLE=$(echo "$CMD" | cut -d= -f2)
    TAGS_ARG=$(echo "$ARGS" | grep -o 'tags=[^ ]*' | cut -d= -f2)
    MY_NAME=$(_get_my_name)
    COORDINATOR=$(_get_coordinator)

    if [ -z "$MY_NAME" ]; then
      echo "오류: inter-session에 연결되어 있지 않습니다. 먼저 /nco-inter-session 을 실행하세요."
      exit 1
    fi

    # tags 자동 추론 (미지정 시)
    if [ -z "$TAGS_ARG" ]; then
      TAGS_ARG=$(python3 - << 'PYEOF'
import subprocess, os
from pathlib import Path
from collections import Counter

tags = set()

# git log 분석
try:
    log = subprocess.check_output(
        ["git", "log", "--oneline", "-20"],
        stderr=subprocess.DEVNULL, cwd=os.getcwd()
    ).decode()
    kw_map = {
        "fix": "bugfix", "bug": "bugfix", "test": "test", "review": "review",
        "feat": "feature", "add": "feature", "impl": "impl", "build": "build",
        "deploy": "devops", "ci": "devops", "docker": "devops", "refactor": "refactor",
        "docs": "docs", "design": "design", "arch": "design"
    }
    for kw, tag in kw_map.items():
        if kw in log.lower():
            tags.add(tag)
except Exception:
    pass

# 파일 확장자 분석
ext_map = {
    ".py": "python", ".ts": "typescript", ".tsx": "react",
    ".js": "javascript", ".jsx": "react", ".go": "go",
    ".rs": "rust", ".java": "java", ".swift": "swift",
    ".css": "frontend", ".scss": "frontend", ".html": "frontend",
    ".md": "docs", ".sql": "database", ".sh": "devops",
    ".yaml": "devops", ".yml": "devops", ".tf": "devops"
}
try:
    exts = Counter()
    for f in Path(os.getcwd()).rglob("*"):
        if f.is_file() and not any(p.startswith('.') for p in f.parts):
            exts[f.suffix] += 1
    for ext, tag in ext_map.items():
        if exts.get(ext, 0) > 0:
            tags.add(tag)
except Exception:
    pass

print(",".join(sorted(tags)) if tags else "general")
PYEOF
      )
      echo "tags 자동 추론: $TAGS_ARG"
    fi

    # team.json 업데이트
    python3 - "$TEAM_JSON" "$MY_NAME" "$ROLE" "$TAGS_ARG" << 'PYEOF'
import sys, json, time
from pathlib import Path

path = Path(sys.argv[1])
name = sys.argv[2]
role = sys.argv[3]
tags = [t.strip() for t in sys.argv[4].split(",") if t.strip()]

path.parent.mkdir(parents=True, exist_ok=True)

# 기존 team.json 로드 또는 초기화
if path.exists():
    try:
        data = json.loads(path.read_text())
    except Exception:
        data = {}
else:
    data = {}

if "version" not in data:
    data = {
        "version": 1,
        "coordinator": "claude-1",
        "sessions": {},
        "tasks": [],
        "votes": {},
        "sub_coordinators": {}
    }

now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
existing = data["sessions"].get(name, {})

data["sessions"][name] = {
    "preferred_role": role,
    "actual_role": role,
    "tags": tags,
    "load": existing.get("load", 0),
    "joined_at": existing.get("joined_at", now),
    "last_seen": now
}
data["version"] += 1

path.write_text(json.dumps(data, ensure_ascii=False, indent=2))
print(f"등록 완료: {name} / role={role} / tags={tags}")
PYEOF

    # P4: 등록 전 stale 세션 자동 정리 (TTL 60s)
    CLEANUP_RESULT=$(python3 - "$TEAM_JSON" "60" << 'PYEOF'
import sys, json, time
from pathlib import Path
from datetime import datetime

path = Path(sys.argv[1])
ttl = int(sys.argv[2])

if not path.exists():
    sys.exit(0)

data = json.loads(path.read_text())
now = time.time()
removed = []

for name, s in list(data.get("sessions", {}).items()):
    last_seen = s.get("last_seen", "")
    if not last_seen:
        del data["sessions"][name]
        removed.append(name)
        continue
    try:
        last_ts = datetime.fromisoformat(last_seen.replace("Z", "+00:00")).timestamp()
        if now - last_ts > ttl:
            del data["sessions"][name]
            removed.append(name)
    except Exception:
        pass

for t in data.get("tasks", []):
    if t.get("assigned_to") in removed and t.get("status") == "in-progress":
        t["status"] = "orphaned"
        t["orphaned_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

if removed:
    data["version"] += 1
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2))
    print(f"auto-cleanup: {', '.join(removed)} 제거됨")
PYEOF
    )
    [ -n "$CLEANUP_RESULT" ] && echo "$CLEANUP_RESULT"

    # coordinator에게 joined 알림
    _send_msg "$COORDINATOR" "status: role=${ROLE} joined | name=${MY_NAME} | tags=${TAGS_ARG}"
    echo "coordinator(${COORDINATOR})에게 참여 알림 전송 완료."
    ;;

  list)
    python3 - "$TEAM_JSON" << 'PYEOF'
import sys, json, time
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    print("team.json 없음. /nco-team-session role=<역할> 로 먼저 등록하세요.")
    sys.exit(0)

data = json.loads(path.read_text())
now = time.time()

print(f"=== Inter-Session Team (v{data.get('version','?')}) ===")
print(f"coordinator: {data.get('coordinator','?')}")
print()

sessions = data.get("sessions", {})
print(f"[ 멤버 {len(sessions)}명 ]")
for name, s in sessions.items():
    role = s.get("actual_role", "?")
    tags = ",".join(s.get("tags", []))
    load = s.get("load", 0)
    last = s.get("last_seen", "")
    print(f"  {name:20s} role={role:12s} load={load} tags=[{tags}]")

tasks = data.get("tasks", [])
if tasks:
    print()
    print(f"[ 태스크 {len(tasks)}개 ]")
    for t in tasks:
        tid = t.get("id", "?")
        status = t.get("status", "?")
        assigned = t.get("assigned_to", "unassigned")
        content = t.get("content", "")[:50]
        deps = t.get("depends_on", [])
        dep_str = f" depends={deps}" if deps else ""
        print(f"  [{status:12s}] {tid:15s} → {assigned:20s} | {content}{dep_str}")
else:
    print()
    print("[ 태스크 없음 ]")
PYEOF
    ;;

  task)
    # task <내용> [tags=<필요태그>] [deadline=<초>]
    CONTENT=$(echo "$ARGS" | sed 's/^task //' | sed 's/tags=[^ ]*//' | sed 's/deadline=[^ ]*//' | xargs)
    REQUIRED_TAGS=$(echo "$ARGS" | grep -o 'tags=[^ ]*' | cut -d= -f2)
    DEADLINE=$(echo "$ARGS" | grep -o 'deadline=[^ ]*' | cut -d= -f2)
    MY_NAME=$(_get_my_name)

    if [ -z "$CONTENT" ]; then
      echo "사용법: /nco-team-session task <내용> [tags=<태그>] [deadline=<초>]"
      exit 1
    fi

    # task 생성 + 자동 dispatch
    ASSIGNED=$(python3 - "$TEAM_JSON" "$CONTENT" "$REQUIRED_TAGS" "$DEADLINE" "$MY_NAME" << 'PYEOF'
import sys, json, time, uuid
from pathlib import Path

path = Path(sys.argv[1])
content = sys.argv[2]
required_tags = [t.strip() for t in sys.argv[3].split(",") if t.strip()] if sys.argv[3] else []
deadline_sec = int(sys.argv[4]) if sys.argv[4] else 300
creator = sys.argv[5]

if not path.exists():
    print("ERROR: team.json 없음")
    sys.exit(1)

data = json.loads(path.read_text())
now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
deadline_ts = time.strftime("%Y-%m-%dT%H:%M:%SZ",
                            time.gmtime(time.time() + deadline_sec))

# tags 매칭 + load 최소 세션 선택
best = None
best_load = 9999
for name, s in data["sessions"].items():
    if name == creator:
        continue
    sess_tags = set(s.get("tags", []))
    if required_tags and not set(required_tags).intersection(sess_tags):
        continue
    load = s.get("load", 0)
    if load < best_load:
        best_load = load
        best = name

if not best:
    # fallback: load 최소 세션 (tags 무시)
    for name, s in data["sessions"].items():
        if name == creator:
            continue
        load = s.get("load", 0)
        if load < best_load:
            best_load = load
            best = name

if not best:
    print("ERROR: 위임 가능한 세션 없음")
    sys.exit(1)

task_id = "task-" + str(uuid.uuid4())[:8]
task = {
    "id": task_id,
    "content": content,
    "required_tags": required_tags,
    "assigned_to": best,
    "status": "in-progress",
    "depends_on": [],
    "checkpoint": "",
    "deadline": deadline_ts,
    "created_by": creator,
    "created_at": now
}

data["tasks"].append(task)
# load 증가
data["sessions"][best]["load"] = data["sessions"][best].get("load", 0) + 1
data["version"] += 1
path.write_text(json.dumps(data, ensure_ascii=False, indent=2))

print(f"{best}|{task_id}")
PYEOF
    )

    if echo "$ASSIGNED" | grep -q "^ERROR:"; then
      echo "$ASSIGNED"
      exit 1
    fi

    TARGET=$(echo "$ASSIGNED" | cut -d'|' -f1)
    TASK_ID=$(echo "$ASSIGNED" | cut -d'|' -f2)

    echo "태스크 생성: $TASK_ID → $TARGET"
    _send_msg "$TARGET" "delegate: [${MY_NAME} → ${TARGET}] task-id:${TASK_ID}
내용: ${CONTENT}
required_tags: ${REQUIRED_TAGS:-any}
완료 시: /nco-team-session done ${TASK_ID} <결과요약>"
    ;;

  done)
    # done <task-id> <결과요약>
    TASK_ID=$(echo "$ARGS" | awk '{print $2}')
    SUMMARY=$(echo "$ARGS" | cut -d' ' -f3-)
    MY_NAME=$(_get_my_name)
    COORDINATOR=$(_get_coordinator)

    if [ -z "$TASK_ID" ] || [ -z "$SUMMARY" ]; then
      echo "사용법: /nco-team-session done <task-id> <결과요약>"
      exit 1
    fi

    # team.json 업데이트
    python3 - "$TEAM_JSON" "$TASK_ID" "$MY_NAME" << 'PYEOF'
import sys, json, time
from pathlib import Path

path = Path(sys.argv[1])
task_id = sys.argv[2]
my_name = sys.argv[3]

if not path.exists():
    print("team.json 없음")
    sys.exit(1)

data = json.loads(path.read_text())
now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

found = False
for t in data["tasks"]:
    if t["id"] == task_id:
        t["status"] = "done"
        t["completed_at"] = now
        found = True
        # load 감소
        assigned = t.get("assigned_to", "")
        if assigned in data["sessions"]:
            data["sessions"][assigned]["load"] = max(0, data["sessions"][assigned].get("load", 1) - 1)
        break

if not found:
    print(f"task-id '{task_id}' 없음")
    sys.exit(1)

data["version"] += 1
path.write_text(json.dumps(data, ensure_ascii=False, indent=2))
print(f"완료 처리: {task_id}")
PYEOF

    _send_msg "$COORDINATOR" "done: task-id=${TASK_ID} | by=${MY_NAME} | ${SUMMARY}"
    echo "coordinator(${COORDINATOR})에게 완료 보고 전송."
    ;;

  status)
    MY_NAME=$(_get_my_name)
    python3 - "$TEAM_JSON" "$MY_NAME" << 'PYEOF'
import sys, json
from pathlib import Path

path = Path(sys.argv[1])
my_name = sys.argv[2]

print(f"=== 내 세션 상태 ===")
print(f"이름: {my_name}")

if not path.exists():
    print("team.json 없음 (미등록)")
    sys.exit(0)

data = json.loads(path.read_text())
s = data.get("sessions", {}).get(my_name)
if not s:
    print("팀 미등록. /nco-team-session role=<역할> 로 등록하세요.")
    sys.exit(0)

print(f"역할: {s.get('actual_role', '?')} (preferred: {s.get('preferred_role', '?')})")
print(f"tags: {s.get('tags', [])}")
print(f"load: {s.get('load', 0)} (미완료 task 수)")
print(f"last_seen: {s.get('last_seen', '?')}")

my_tasks = [t for t in data.get("tasks", [])
            if t.get("assigned_to") == my_name and t.get("status") == "in-progress"]
if my_tasks:
    print()
    print(f"진행 중인 태스크 {len(my_tasks)}개:")
    for t in my_tasks:
        print(f"  [{t['id']}] {t.get('content','')[:60]}")
PYEOF
    ;;

  deregister)
    MY_NAME=$(_get_my_name)
    COORDINATOR=$(_get_coordinator)

    python3 - "$TEAM_JSON" "$MY_NAME" << 'PYEOF'
import sys, json
from pathlib import Path

path = Path(sys.argv[1])
my_name = sys.argv[2]

if not path.exists():
    print("team.json 없음")
    sys.exit(0)

data = json.loads(path.read_text())
if my_name in data.get("sessions", {}):
    del data["sessions"][my_name]
    data["version"] += 1
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2))
    print(f"{my_name} 팀 탈퇴 완료")
else:
    print(f"{my_name} 는 팀에 등록되지 않았음")
PYEOF

    _send_msg "$COORDINATOR" "status: deregister | name=${MY_NAME} | 팀 탈퇴"
    ;;

  cleanup)
    # TTL 초과 세션 제거 + orphaned task 처리
    # [선택] ttl=<초> (기본 60)
    TTL=$(echo "$ARGS" | grep -o 'ttl=[^ ]*' | cut -d= -f2)
    TTL="${TTL:-60}"
    MY_NAME=$(_get_my_name)
    COORDINATOR=$(_get_coordinator)

    RESULT=$(python3 - "$TEAM_JSON" "$TTL" << 'PYEOF'
import sys, json, time
from pathlib import Path
from datetime import datetime, timezone

path = Path(sys.argv[1])
ttl = int(sys.argv[2])

if not path.exists():
    print("team.json 없음")
    sys.exit(0)

data = json.loads(path.read_text())
now = time.time()
removed_sessions = []
orphaned_tasks = []

# 1) TTL 초과 세션 제거
sessions = data.get("sessions", {})
stale = []
for name, s in sessions.items():
    last_seen = s.get("last_seen", "")
    if not last_seen:
        stale.append(name)
        continue
    try:
        # ISO 8601 파싱
        last_ts = datetime.fromisoformat(last_seen.replace("Z", "+00:00")).timestamp()
        if now - last_ts > ttl:
            stale.append(name)
    except Exception:
        pass

for name in stale:
    del data["sessions"][name]
    removed_sessions.append(name)

# 2) 제거된 세션의 in-progress task → orphaned
for t in data.get("tasks", []):
    if (t.get("assigned_to") in removed_sessions
            and t.get("status") == "in-progress"):
        t["status"] = "orphaned"
        t["orphaned_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        orphaned_tasks.append(t["id"])
        # load는 이미 세션이 제거됐으므로 스킵

if removed_sessions or orphaned_tasks:
    data["version"] += 1
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2))

if removed_sessions:
    print(f"제거된 세션({ttl}s TTL 초과): {', '.join(removed_sessions)}")
if orphaned_tasks:
    print(f"orphaned task: {', '.join(orphaned_tasks)}")
if not removed_sessions and not orphaned_tasks:
    print(f"정리할 항목 없음 (TTL={ttl}s)")
PYEOF
    )

    echo "$RESULT"

    # coordinator에게 보고 (변경이 있을 때만)
    if echo "$RESULT" | grep -qE "제거된|orphaned"; then
      _send_msg "$COORDINATOR" "status: cleanup 완료 | ttl=${TTL}s | ${RESULT}"
    fi
    ;;

  "")
    echo "사용법: /nco-team-session <서브커맨드>"
    echo ""
    echo "  role=<역할> [tags=<tag1,tag2>]        — 팀 등록"
    echo "  list                                   — 팀 멤버 + 태스크 현황"
    echo "  task <내용> [tags=<태그>] [deadline=<초>] — 태스크 생성 + 자동 위임"
    echo "  done <task-id> <결과요약>              — 태스크 완료 보고"
    echo "  status                                 — 내 세션 현황"
    echo "  cleanup [ttl=<초>]                     — TTL 초과 세션 정리 + orphaned task 처리"
    echo "  deregister                             — 팀 탈퇴"
    ;;

  *)
    echo "알 수 없는 명령: $CMD"
    echo "사용법: /nco-team-session [role=<역할>|list|task|done|status|deregister]"
    ;;
esac
