> 채택 메모 (kangnote-claude-1, 2026-07-03): copilot(Researcher) 설계 → Commander 검토·승인. 보정 1건 — 전문(full packet) 저장 경로는 `~/.llm/last-handoff.json`이 아니라 fleet 관례인 `~/.claude/data/inter-session/messages.log`(JSONL, msg_id로 grep) 또는 발신측이 명시한 T1 파일 경로를 사용한다.

# NCO Handoff Packet v1 — Structured Inter-Session Delegation

## 1. Schema & Required Fields

```json
{
  "schema_version": "1.0",
  "sender": {
    "agent_name": "copilot",
    "session_id": "abc123",
    "timestamp": "2026-07-03T00:14:08Z"
  },
  "task": {
    "id": "task_hg_W2ck9AI_8atiL",
    "description": "Brief description of what was delegated"
  },
  "outcome": "done|partial|failed|question",
  "summary": "Single sentence result or blocker",
  "evidence": [
    {
      "tier": "T1|T2|T3|T4",
      "method": "file_read|http_body|process_check|exit_code|natural_language",
      "claim": "What we're asserting (e.g., 'API endpoint returns 200')",
      "raw": "Ground truth sample or source (file path, HTTP response, exit code, or quote)"
    }
  ],
  "artifacts": [
    {
      "type": "file|commit|log_url",
      "location": "/path/to/file or abc1234 (commit hash) or http://url",
      "description": "What this artifact proves or represents"
    }
  ],
  "unverified": [
    "String describing known unknowns, e.g., 'Redis persistence not tested under failover'"
  ],
  "resume": {
    "next_command": "npm run build && npm test",
    "context": "Stopped at: src/server/gateway.ts line 127; next step is to test new /api/mesh endpoint",
    "blockers": ["API key not yet injected", "Database migration pending"]
  },
  "usage": {
    "tokens_input": 15000,
    "tokens_output": 8000,
    "wall_time_seconds": 120
  }
}
```

### Field Definitions

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `schema_version` | string | ✓ | Semantic version; v1 receivers ignore unknown versions |
| `sender.{agent_name, session_id, timestamp}` | object | ✓ | Identify delegator for audit & re-contact |
| `task.{id, description}` | object | ✓ | Link back to orchestration context |
| `outcome` | enum | ✓ | `done` (fully complete) / `partial` (some work done, rest blocked) / `failed` (could not proceed) / `question` (decision needed from receiver) |
| `summary` | string | ✓ | Max 200 chars; one-liner result or blocker |
| `evidence[]` | array | ✓ | At least one T1/T2 evidence for `done`; T4-only insufficient |
| `tier` | enum | ✓ | **T1** (file/DB/HTTP body) **T2** (process/port exists) **T3** (exit code/status string) **T4** (natural language assertion) |
| `method` | enum | ✓ | How evidence was gathered |
| `raw` | string | ✓ | Exact output; quote or reference, no interpretation |
| `artifacts[]` | array | ○ | Paths to generated files, commit hashes, or logs |
| `unverified[]` | array | ○ | Known gaps; receiver decides if acceptable |
| `resume` | object | ○ | Commands and context to continue; mandatory if `partial` |
| `usage` | object | ○ | Token/time tracking for cost accounting |

---

## 2. Evidence Trust Policy (Receiver Validation)

Receivers use this matrix to decide whether to accept outcome:

```
Outcome  | Min Evidence Tier | Examples of Acceptable Proofs
---------|-------------------|-----------------------------------------
done     | T1 + one of T2/T3 | File exists (T1) + exit 0 (T3) ✓
         |                   | HTTP 200 (T1) + process running (T2) ✓
         |                   | T4-only claim "tests passed" ✗ REJECTED
---------+-------------------|-----------------------------------------
partial  | T1 minimum        | "Compiled 3/5 modules, error in module 4" + build.log (T1) ✓
         |                   | Exit code 1, no artifact ✗ REJECTED (no evidence of what worked)
---------+-------------------|-----------------------------------------
failed   | T1 or T3          | stderr output (T1) or exit 127 (T3) ✓
         |                   | "Ran out of memory" without stack trace (T4) ✗ ESCALATE
---------+-------------------|-----------------------------------------
question | context + T1 edge | "Path guard blocks /etc/passwd: confirm policy?" (T1: guard log) ✓
         | case              | "Need your API key to proceed" (T4 only) — wait for context
```

**Rejection protocol**: If evidence insufficient, receiver sends back `question` packet with what evidence tier they require.

---

## 3. Backward Compatibility: Wrapping Legacy Prefix Protocol

### Sending (Wrapper)
```
Old: done: API endpoint created at POST /api/mesh
New: done: {<handoff_packet_json>}
```

Receiving systems must:
1. Parse prefix (done:/status:/error:/question:)
2. If remainder starts with `{`, deserialize JSON → use schema validation
3. Else → treat as legacy free-text; convert to minimal packet:
   ```json
   { "outcome": "done", "summary": "...", "evidence": [{"tier": "T4", "method": "natural_language", "raw": "..."}] }
   ```

### Truncation (400-char limit on inter-session bus)
Place `summary` and `outcome` first (high-priority info), append JSON path or index:
```
done: outcome=done, summary='Build succeeded. Full evidence at .claude/data/inter-session/messages.log (msg_id로 grep)'
```

Receivers then fetch the full packet from `~/.claude/data/inter-session/messages.log` (JSONL) by msg_id lookup.

---

## 4. Minimal Implementation Path

### Phase 1: send.py Wrapper (Week 1)
```python
import json, sys, os
from datetime import datetime

# Minimal sender:
packet = {
    "schema_version": "1.0",
    "sender": {"agent_name": os.getenv("AGENT_NAME", "unknown"), "session_id": os.getenv("SESSION_ID"), "timestamp": datetime.utcnow().isoformat()},
    "task": {"id": sys.argv[1], "description": sys.argv[2]},
    "outcome": sys.argv[3],  # done|partial|failed|question
    "summary": sys.argv[4],
    "evidence": json.loads(sys.argv[5]) if len(sys.argv) > 5 else [],
    "artifacts": json.loads(sys.argv[6]) if len(sys.argv) > 6 else []
}
print(f"done: {json.dumps(packet)}")
```

Usage: `python send.py task_id "desc" done "result" '[{"tier":"T1","method":"file_read","raw":"/path"}]'`

### Phase 2: Receiver validate.py — 구현 완료 (2026-07-03, kangnote-claude-1)
수신측 통합: `claude/hooks/inter-session-auto-responder.sh`의 `annotate_handoff_line()` — 수신 라인이 `done|partial|failed|question: {json}` 형식이면 handoff-validate.py로 검증해 `[HANDOFF:ACCEPT]` / `[HANDOFF:REJECT reason=...]` 주석을 붙여 LLM에 노출. truncated/청크 라인·자유텍스트·validator 부재 시 무주석 통과(fail-open 하위호환). 경로 오버라이드: `HANDOFF_VALIDATE_BIN`.

#### 원 설계 (참고)
Phase 2: Receiver validate.py (Week 2)
```python
import json, sys

packet = json.loads(sys.argv[1])
# 티어는 숫자 랭크로 비교한다 (낮을수록 강한 증거). 문자열 비교는 "T4" >= "T1"이
# 사전순으로 참이 되어 정책이 정반대로 뒤집히므로 금지 (2026-07-03 리뷰 수정).
RANK = {"T1": 1, "T2": 2, "T3": 3, "T4": 4}
ranks = sorted(RANK.get(e["tier"], 4) for e in packet.get("evidence", []))

outcome = packet["outcome"]
ok = True
reason = ""
if outcome == "done":
    # §2 정책 그대로: T1 필수 + T2/T3 중 하나 추가
    ok = 1 in ranks and any(r in (2, 3) for r in ranks)
    reason = "done requires T1 plus one of T2/T3"
elif outcome == "partial":
    ok = 1 in ranks
    reason = "partial requires at least one T1"
elif outcome == "failed":
    ok = any(r <= 3 for r in ranks)
    reason = "failed requires T1-T3 evidence"
# question은 증거 없이 허용

if not ok:
    print(f"REJECT: {reason}. Got tiers={[e['tier'] for e in packet.get('evidence', [])]}")
    sys.exit(1)
print(f"ACCEPT: {packet['summary']}")
```

### v1.1 — 절단 참조의 크로스머신 fetch (2026-07-03 구현)
절단 시 전문을 발신측 로컬 파일 대신 **NCO 서버에 POST 영속**하고 `handoff_id` 참조로 교체:
`'. Full packet: handoff_id=<id> (GET <base>/api/handoff?task_id=<task_id>)`
- base URL: `NCO_HANDOFF_API` → `FLEET_CENTRAL_URL` → `http://localhost:6200` 순 폴백
- 서버 불달/거부 시 구 로컬 파일 방식 폴백 + `[unfetchable-local]` 마커로 수신측에 한계 명시
- 발신측 summary는 스펙 §1(≤200자)로 클램프 — 서버 스키마가 400으로 거부하는 스펙 위반 방지

### Phase 3: NCO Mesh Integration (Week 3)
Update `src/core/event-bus.ts` to emit handoff packets on `session:handoff` event type.

---

## 5. Example Packets

### Example 1: Done (with T1 + T3 evidence)
```json
{
  "schema_version": "1.0",
  "sender": {"agent_name": "codex", "session_id": "xyz789", "timestamp": "2026-07-03T00:30:00Z"},
  "task": {"id": "task_impl_gateway", "description": "Implement /api/mesh POST endpoint"},
  "outcome": "done",
  "summary": "Endpoint implemented and tested; 5/5 unit tests pass",
  "evidence": [
    {
      "tier": "T1",
      "method": "file_read",
      "claim": "New route file exists with handler",
      "raw": "File: src/server/routes/mesh.ts contains POST /api/mesh handler with schema validation"
    },
    {
      "tier": "T3",
      "method": "exit_code",
      "claim": "All tests pass",
      "raw": "npm test mesh.test.ts → exit 0; 5 tests passed"
    }
  ],
  "artifacts": [
    {"type": "file", "location": "src/server/routes/mesh.ts", "description": "Route implementation"},
    {"type": "commit", "location": "a1b2c3d4", "description": "Commit message: feat: add POST /api/mesh with validation"}
  ],
  "unverified": ["Load testing under 1000 req/sec not yet run"],
  "resume": {"next_command": "npm run build && npm start", "context": "Ready for integration test in next session"},
  "usage": {"tokens_input": 12000, "tokens_output": 5500, "wall_time_seconds": 180}
}
```

### Example 2: Partial (with blocker, T1 evidence for what worked)
```json
{
  "schema_version": "1.0",
  "sender": {"agent_name": "aider", "session_id": "def456", "timestamp": "2026-07-03T00:45:00Z"},
  "task": {"id": "task_refactor_auth", "description": "Refactor auth module to use OIDC"},
  "outcome": "partial",
  "summary": "OIDC config layer complete; blocked on Redis key rotation not yet seeded",
  "evidence": [
    {
      "tier": "T1",
      "method": "file_read",
      "claim": "OIDC provider module created",
      "raw": "src/auth/oidc.ts: 234 lines, includes discovery, token validation, user mapping"
    },
    {
      "tier": "T1",
      "method": "http_body",
      "claim": "OIDC discovery endpoint reachable",
      "raw": "GET https://auth-provider.example/.well-known/openid-configuration → 200 OK; keys_uri found"
    }
  ],
  "artifacts": [
    {"type": "file", "location": "src/auth/oidc.ts", "description": "OIDC module"},
    {"type": "file", "location": "db/migrations/006-oidc-keys.sql", "description": "Migration ready but not applied"}
  ],
  "unverified": [
    "Redis key expiration policy not yet implemented",
    "Fallback to local cache if Redis down untested"
  ],
  "resume": {
    "next_command": "npm run migrate && npm test auth",
    "context": "Migration 006 ready. Next: apply migration, then run auth tests. Blocker: Redis seed script at config/redis-oidc-seed.sh needs execution.",
    "blockers": ["Redis must be running", "API key OIDC_CLIENT_SECRET must be in .env"]
  },
  "usage": {"tokens_input": 18000, "tokens_output": 9200, "wall_time_seconds": 420}
}
```

---

## 6. Receiver Checklist (Copy for integration)

When receiving a handoff packet:
- [ ] Deserialize and check `schema_version` (reject if > current)
- [ ] Verify `outcome` matches evidence tier policy (see §2)
- [ ] If T4-only and outcome is `done` → reject; send back `question` packet
- [ ] Extract `resume.next_command` and `resume.blockers`
- [ ] Check that all `artifacts` locations exist (files/commits accessible)
- [ ] If `unverified` contains showstoppers for your task → escalate with question
- [ ] Log sender/task/timestamp for audit trail
- [ ] Proceed or escalate

---

## 7. Non-Goals (v1 Out of Scope)

- File diffs (use commit hash references instead)
- Performance profiling details (covered by `usage`)
- Multi-file diff bundles (too large; use artifacts + git refs)
- Consensus voting records (separate feature)

---

**Version**: 1.0 | **Date**: 2026-07-03 | **Status**: Specification (ready for Phase 1 pilot on dev sessions)
