#!/bin/bash
# Deterministic regression tests for the Stop-hook remaining-work contract.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/claude/hooks/nco-autoloop-stop.sh"
GOAL_CHECK="$ROOT/claude/hooks/session-goal-check.sh"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nco-autoloop-test.XXXXXX")
PASS=0
FAIL=0

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

record() {
  local ok="$1" name="$2" detail="${3:-}"
  if [ "$ok" = "1" ]; then
    PASS=$((PASS + 1))
    printf 'ok - %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf 'not ok - %s%s\n' "$name" "${detail:+: $detail}"
  fi
}

make_transcript() {
  local name="$1" gap="$2" remaining="$3" resume="$4"
  local remaining_label="${5:-미검증항목}"
  local tx="$TMP_DIR/autoloop-${name}.jsonl"
  python3 - "$tx" "$gap" "$remaining" "$resume" "$remaining_label" <<'PY'
import json, sys
path, gap, remaining, resume, remaining_label = sys.argv[1:]
receipt = "\n".join([
    "작업 결과입니다.",
    "## 검증 영수증",
    "- [변경] 테스트 픽스처",
    "- [검증방법] Bash 테스트 → 예상 종료 코드",
    "- [등급] T1",
    f"- [Gap] {gap}%",
])
if remaining != "__omit__":
    receipt += f"\n- [{remaining_label}] {remaining}"
if resume != "__omit__":
    receipt += f"\n- [자동재진행] {resume}"
rows = [
    {"type": "user", "message": {"content": "요청한 작업을 끝까지 처리해."}},
    {"type": "assistant", "message": {"content": [{"type": "text", "text": receipt}]}},
]
with open(path, "w", encoding="utf-8") as f:
    for row in rows:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")
PY
  printf '%s\n' "$tx"
}

run_hook() {
  local tx="$1" cap="${2:-10}"
  local output rc
  output=$(printf '{"transcript_path":"%s","stop_hook_active":false}\n' "$tx" |
    NCO_AUTOLOOP_GOAL_CHECK="$GOAL_CHECK" NCO_AUTOLOOP_STATE_DIR="$TMP_DIR" \
      NCO_AUTOLOOP_TOTAL_CAP="$cap" \
      bash "$HOOK" 2>&1)
  rc=$?
  printf '%s\n%s\n' "$rc" "$output"
}

goal_json() {
  GOAL_CHECK_THRESHOLD=100 bash "$GOAL_CHECK" "$1" 2>/dev/null
}

# Gap 100 + no remaining work + done is the only ordinary completion state.
tx=$(make_transcript done 100 없음 done)
result=$(run_hook "$tx")
rc=${result%%$'\n'*}
record "$([ "$rc" = 0 ] && echo 1 || echo 0)" "done exits normally" "rc=$rc"
json=$(goal_json "$tx")
record "$(printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(1 if d["verdict"]=="COMPLETE" and d["auto_resume"]=="done" else 0)')" \
  "done is machine-readable"

# Completion fields are fail-closed: both the state marker and explicit empty remainder are required.
tx=$(make_transcript missing-resume 100 없음 __omit__)
result=$(run_hook "$tx")
rc=${result%%$'\n'*}
record "$([ "$rc" = 2 ] && echo 1 || echo 0)" "missing auto-resume marker re-enters" "rc=$rc"
tx=$(make_transcript missing-remaining 100 __omit__ done)
result=$(run_hook "$tx")
rc=${result%%$'\n'*}
record "$([ "$rc" = 2 ] && echo 1 || echo 0)" "missing remaining-work field re-enters" "rc=$rc"
tx=$(make_transcript wrong-label 100 없음 done '남은 작업')
result=$(run_hook "$tx")
rc=${result%%$'\n'*}
record "$([ "$rc" = 2 ] && echo 1 || echo 0)" "alternate remaining-work label cannot complete" "rc=$rc"
tx=$(make_transcript nonexact-none 100 none done)
result=$(run_hook "$tx")
rc=${result%%$'\n'*}
record "$([ "$rc" = 2 ] && echo 1 || echo 0)" "nonexact none sentinel cannot complete" "rc=$rc"
tx=$(make_transcript completion-word 100 완료 done)
result=$(run_hook "$tx")
rc=${result%%$'\n'*}
record "$([ "$rc" = 2 ] && echo 1 || echo 0)" "completion word cannot replace explicit 없음" "rc=$rc"

# Explicit continue wins even if a stale/optimistic Gap says 100.
tx=$(make_transcript force-continue 100 없음 continue)
result=$(run_hook "$tx")
rc=${result%%$'\n'*}
record "$([ "$rc" = 2 ] && echo 1 || echo 0)" "continue forces re-entry" "rc=$rc"

# A contradictory done marker cannot hide an incomplete receipt.
tx=$(make_transcript invalid-done 80 배포검증 done)
result=$(run_hook "$tx")
rc=${result%%$'\n'*}
record "$([ "$rc" = 2 ] && echo 1 || echo 0)" "done with Gap below 100 re-enters" "rc=$rc"

# Concrete remaining work is injected into the next turn.
tx=$(make_transcript remaining 80 'Docker 이미지 빌드' continue)
result=$(run_hook "$tx")
rc=${result%%$'\n'*}
record "$([ "$rc" = 2 ] && echo 1 || echo 0)" "remaining work re-enters" "rc=$rc"
record "$(printf '%s' "$result" | grep -q 'Docker 이미지 빌드' && echo 1 || echo 0)" \
  "remaining item is included in feedback"

# Human authority/external-state blockers stop safely and preserve the reason.
tx=$(make_transcript blocked 80 '프로덕션 배포 승인' 'blocked: 사용자 승인 필요')
result=$(run_hook "$tx")
rc=${result%%$'\n'*}
record "$([ "$rc" = 0 ] && echo 1 || echo 0)" "blocked exits normally" "rc=$rc"
json=$(goal_json "$tx")
record "$(printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(1 if d["verdict"]=="BLOCKED" and d["auto_resume_reason"]=="사용자 승인 필요" else 0)')" \
  "blocked reason is machine-readable"
tx=$(make_transcript blocked-no-reason 80 '프로덕션 배포 승인' blocked)
result=$(run_hook "$tx")
rc=${result%%$'\n'*}
record "$([ "$rc" = 2 ] && echo 1 || echo 0)" "blocked without a reason re-enters" "rc=$rc"
tx=$(make_transcript blocked-empty-sentinel 80 '프로덕션 배포 승인' 'blocked: 없음')
result=$(run_hook "$tx")
rc=${result%%$'\n'*}
record "$([ "$rc" = 2 ] && echo 1 || echo 0)" "blocked with empty sentinel re-enters" "rc=$rc"

# Chat/query turns have no receipt and must never self-perpetuate.
chat_tx="$TMP_DIR/autoloop-chat.jsonl"
python3 - "$chat_tx" <<'PY'
import json, sys
rows = [
    {"type": "user", "message": {"content": "오늘 날짜가 뭐야?"}},
    {"type": "assistant", "message": {"content": [{"type": "text", "text": "2026-08-03입니다."}]}},
]
with open(sys.argv[1], "w", encoding="utf-8") as f:
    for row in rows:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")
PY
result=$(run_hook "$chat_tx")
rc=${result%%$'\n'*}
record "$([ "$rc" = 0 ] && echo 1 || echo 0)" "chat without receipt does not loop" "rc=$rc"

# Only the newest receipt block controls the stop decision.
latest_tx="$TMP_DIR/autoloop-latest.jsonl"
python3 - "$latest_tx" <<'PY'
import json, sys
text = """## 검증 영수증
- [Gap] 80%
- [미검증항목] 이전 항목
- [자동재진행] continue

후속 작업까지 검증했습니다.
## 검증 영수증
- [변경] 후속 작업 완료
- [검증방법] Bash 테스트
- [등급] T1
- [Gap] 100%
- [미검증항목] 없음
- [자동재진행] done"""
rows = [
    {"type": "user", "message": {"content": "후속 작업까지 처리해."}},
    {"type": "assistant", "message": {"content": [{"type": "text", "text": text}]}},
]
with open(sys.argv[1], "w", encoding="utf-8") as f:
    for row in rows:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")
PY
result=$(run_hook "$latest_tx")
rc=${result%%$'\n'*}
record "$([ "$rc" = 0 ] && echo 1 || echo 0)" "latest receipt supersedes stale receipt" "rc=$rc"

# The hard cap remains the final runaway guard.
tx=$(make_transcript cap 80 '반복 대상' continue)
result=$(run_hook "$tx" 0)
rc=${result%%$'\n'*}
record "$([ "$rc" = 0 ] && echo 1 || echo 0)" "loop cap stops re-entry" "rc=$rc"
record "$(printf '%s' "$result" | grep -q '상한 도달' && echo 1 || echo 0)" \
  "loop cap explains why it stopped"

printf '%s\n' "1..$((PASS + FAIL))" "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
