---
description: NCO 회사 팀에 작업을 위임하고 오케스트레이션합니다.
argument-hint: '[subcommand] [args...]'
---
# /nco-company — 회사 팀에 실작업 위임 (Claude→팀 적극 사용 워크플로우)
#
# 팀은 "passive container"라서 team_id로 태그된 task가 곧 위임이다.
# 위임 = (1) 팀 lead 에이전트에게 POST /api/task 로 task 생성
#        (2) POST /api/teams/<id>/tasks 로 그 task에 team_id 링크
# → 대시보드/메트릭에서 "회사 팀에 위임됨"으로 집계된다.
#
# 사용법:
#   /nco-company list                        — 회사/팀 목록 (lead·멤버·상태)
#   /nco-company orgs                        — 조직(회사) 목록 (id·slug·팀수·매니저)
#   /nco-company metrics                     — 팀 위임률 (몇 % 위임했는지)
#   /nco-company <팀이름|slug> <작업설명>     — 해당 팀에 실작업 위임 (단일 팀)
#   /nco-company run <회사slug> <목표> [--parallel|--pipeline] [--dry-run]
#                                            — 회사 전체 오케스트레이션(팀별 역할 분배)
#   /nco-company status <runId>              — 오케스트레이션 실행 상태 조회
#   /nco-company-cancel <runId>               — 실행 중인 오케스트레이션 취소(확인 필요)
#
# 예: /nco-company "CLI 코어 개발팀" "인증 토큰 만료 버그 재현 테스트 작성"
# 예: /nco-company run research "AI 에이전트 오케스트레이션 최신 동향 리서치"
# 예: /nco-company run research "주제 X 리서치" --dry-run   (분배안만 미리보기)

export NCO_API=http://localhost:6200
export NCO_ARGS="$ARGUMENTS"
export NCO_PROJECT_DIR="$PWD"

if ! curl -s --max-time 3 "$NCO_API/health" >/dev/null 2>&1; then
  echo "❌ NCO 오프라인(:6200). /nco-start 후 재시도."
  exit 0
fi

# 모든 로직은 python이 urllib로 직접 처리 (curl|python stdin 충돌 회피)
python3 <<'PYEOF'
import os, sys, json, urllib.request, urllib.error

API = os.environ["NCO_API"]
ARGS = os.environ.get("NCO_ARGS", "").strip()
PROJECT_DIR = os.environ.get("NCO_PROJECT_DIR", "").strip() or os.getcwd()
parts = ARGS.split(None, 1)
SUB = parts[0] if parts else ""
REST = parts[1] if len(parts) > 1 else ""

def _read(resp):
    return json.loads(resp.read().decode())

def _http(req_or_url, timeout):
    """비2xx 응답도 본문을 파싱해 돌려준다.

    urlopen 은 404/400 에서 HTTPError 를 던진다. 이전에는 이를 잡지 않아
    `/nco-company status <없는 runId>` 가 파이썬 트레이스백을 그대로 토했다.
    서버는 {"error": "..."} 형태의 JSON 본문을 주므로 그것을 반환한다.
    """
    try:
        with urllib.request.urlopen(req_or_url, timeout=timeout) as r:
            return _read(r)
    except urllib.error.HTTPError as e:
        try:
            body = json.loads(e.read().decode())
        except Exception:
            body = {}
        if not isinstance(body, dict):
            body = {"error": str(body)}
        body.setdefault("error", f"HTTP {e.code}")
        body["_status"] = e.code
        return body
    except Exception as e:
        return {"error": f"요청 실패: {e}", "_status": 0}

def get(path):
    return _http(API + path, 10)

def post(path, payload):
    req = urllib.request.Request(API + path, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    return _http(req, 30)

if SUB == "list":
    teams = get("/api/teams").get("teams", [])
    print("회사 팀 %d개:" % len(teams))
    for t in teams:
        mem = ",".join(m.get("ref", "") for m in t.get("members", [])[:5])
        ao = "상시" if t.get("isAlwaysOn") else "-"
        print("  [%-7s] %-26s lead=%-12s %-4s 멤버:%s" % (
            t.get("status", ""), t.get("name", "")[:26], str(t.get("lead")), ao, mem))
        print("           id=%s  slug=%s" % (t.get("id"), t.get("slug")))

elif SUB == "orgs":
    orgs = get("/api/organizations").get("organizations", [])
    print("조직(회사) %d개:" % len(orgs))
    for o in orgs:
        print("  %-22s teams=%-3s mgr=%-20s id=%s slug=%s" % (
            o.get("name", "")[:22], o.get("teamCount"), str(o.get("manager"))[:20],
            o.get("id"), o.get("slug")))

elif SUB == "metrics":
    d = get("/api/teams/metrics")
    print("전체 위임률: %s%%  (%s/%s tasks)" % (
        d["teamDelegationPct"], d["teamTaggedTasks"], d["totalTasks"]))
    print("세션별 팀 위임률:")
    for s in d.get("bySession", [])[:10]:
        print("  %-24s %s/%s (%s%%)" % (s["session"], s["team"], s["total"], s["pct"]))

elif SUB == "run":
    # run <회사slug> <목표> [--parallel|--pipeline] [--dry-run]
    toks = REST.split()
    mode = "pipeline"
    dry = False
    kept = []
    for t in toks:
        if t == "--parallel": mode = "parallel"
        elif t == "--pipeline": mode = "pipeline"
        elif t in ("--dry-run", "--dry"): dry = True
        else: kept.append(t)
    if not kept:
        print("사용법: /nco-company run <회사slug> <목표> [--parallel|--pipeline] [--dry-run]")
        sys.exit(0)
    org = kept[0]
    goal = " ".join(kept[1:]).strip()
    if not goal:
        print("목표가 필요합니다: /nco-company run %s <목표>" % org)
        sys.exit(0)
    known_project_dirs = {
        "nova-cli": os.path.expanduser("~/project/nova-cli"),
        "nova-ax": os.path.expanduser("~/project/nova-ax"),
        "nco-self": os.path.expanduser("~/project/nco"),
    }
    project_dir = known_project_dirs.get(org, PROJECT_DIR)
    resp = post("/api/organizations/%s/orchestrate" % org,
                {"goal": goal, "mode": mode, "dryRun": dry, "projectDir": project_dir})
    run = resp.get("run") if isinstance(resp, dict) else None
    if not run:
        print("❌ 오케스트레이션 시작 실패: %s" % (json.dumps(resp, ensure_ascii=False)[:200]))
        sys.exit(0)
    print("✅ 오케스트레이션 시작: 회사 '%s' | mode=%s%s" % (
        run.get("orgName"), run.get("mode"), " (DRY-RUN)" if dry else ""))
    print("   runId=%s  decomposer=%s" % (run.get("id"), run.get("decomposer")))
    print("   projectDir=%s" % run.get("projectDir"))
    print("   팀 %d개(실행 순서):" % len(run.get("stages", [])))
    for i, s in enumerate(run.get("stages", []), 1):
        print("     %d. %-24s → %s" % (i, s.get("teamName", "")[:24], s.get("executor")))
    print("   진행확인: /nco-company status %s" % run.get("id"))

elif SUB == "status":
    rid = REST.strip() or (SUB if False else "")
    if not rid:
        print("사용법: /nco-company status <runId>")
        sys.exit(0)
    r = get("/api/orchestrate/%s" % rid)
    run = r.get("run") if isinstance(r, dict) else None
    if not run:
        print("❌ run 없음: %s (%s)" % (rid, json.dumps(r, ensure_ascii=False)[:150]))
        sys.exit(0)
    print("회사 '%s' | mode=%s | status=%s | source=%s | 루프 %s회" % (
        run.get("orgName"), run.get("mode"), run.get("status"), run.get("decomposeSource"),
        run.get("iteration", "-")))
    print("  projectDir=%s" % run.get("projectDir"))
    sm = run.get("summary")
    if sm: print("  집계: 성공 %s/%s | 실패 %s | 재시도 %s" % (
        sm.get("succeeded"), sm.get("total"), sm.get("failed"), sm.get("retried")))
    if run.get("error"): print("  error: %s" % run.get("error"))
    if run.get("status") not in ("completed", "failed", "partial", "cancelled", "planned"):
        print("  취소: /nco-company-cancel %s" % rid)
    for i, s in enumerate(run.get("stages", []), 1):
        line = "  %d. [%-10s] %-22s → %-12s" % (
            i, s.get("status"), s.get("teamName", "")[:22], s.get("executor"))
        if s.get("taskId"): line += " task=%s" % s.get("taskId")
        print(line)
        if s.get("subtask"):
            print("       분배: %s" % s.get("subtask", "")[:100].replace("\n", " "))

elif not SUB:
    print("사용법: /nco-company [list | orgs | metrics | run <회사> <목표> | status <runId> | <팀이름> <작업>]")

else:
    if not REST.strip():
        print("작업 설명이 필요합니다: /nco-company <팀이름|slug> <작업>")
        sys.exit(0)
    q = SUB.strip().lower()
    teams = get("/api/teams").get("teams", [])
    cand = [t for t in teams
            if q in (t.get("name", "").lower(), (t.get("slug") or "").lower(), t.get("id", "").lower())
            or q in t.get("name", "").lower() or q in (t.get("slug") or "").lower()]
    if not cand:
        print("❌ 팀 매칭 실패: '%s'. /nco-company list 로 확인." % SUB)
        sys.exit(0)
    if len(cand) > 1:
        exact = [t for t in cand if q in (t.get("name", "").lower(), (t.get("slug") or "").lower())]
        cand = exact or cand
    team = cand[0]
    lead = team.get("lead")
    # executor 해석: 팀 lead가 유효 provider면 lead, 아니면 사용자 정의 라벨일 때 유효 멤버, 최후엔 ollama.
    # (POST /api/task 의 ai 는 반드시 등록된 provider id 여야 함 — 아니면 400 delegation_payload_rejected)
    try:
        known = {a["id"] for a in get("/api/agents").get("agents", [])}
    except Exception:
        known = {"claude-code","opencode","codex","cursor-agent","copilot","openrouter","ollama","agy","hermes"}
    executor = lead if lead in known else next(
        (m["ref"] for m in team.get("members", []) if m.get("ref") in known), "ollama")
    created = post("/api/task", {
        "ai": executor,
        "callerAgentId": "claude-commander",
        "prompt": "[회사팀 위임: %s] %s" % (team["name"], REST),
        # metadata.projectDir 는 필수 (없으면 400 invalid_project_dir)
        "metadata": {"allowProviderFailover": True, "projectDir": PROJECT_DIR,
                     "team_id": team["id"], "delegatedByCompanyWorkflow": True},
    })
    task_id = created.get("taskId") or created.get("id") or (created.get("task") or {}).get("id")
    if not task_id:
        print("❌ task 생성 실패: %s" % (json.dumps(created)[:200]))
        sys.exit(0)
    link = post("/api/teams/%s/tasks" % team["id"], {"taskId": task_id})
    print("✅ 위임 완료: 팀 '%s' (lead=%s, 실행=%s)" % (team["name"], lead, executor))
    print("   task_id=%s  team_id=%s  link_ok=%s" % (task_id, team["id"], link.get("ok")))
    print("   작업: %s" % REST[:80])
    print("   진행확인: curl -s %s/api/teams/%s/tasks | python3 -m json.tool" % (API, team["id"]))
PYEOF
