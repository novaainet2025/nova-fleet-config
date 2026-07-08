#!/bin/bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작 (2026-07-08, 76s 훅스택+BOOTSTRAP 오염 T1)
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
# L2: PostToolUse hook on Edit/Write/MultiEdit — 자동 리뷰 트리거
# 변경 파일에 대해 cursor-agent 리뷰를 백그라운드 로그로 큐잉.
# 재진입 무한루프 방지: NCO_REVIEW_IN_PROGRESS=1 + 60초 파일별 lock.
# stub: 실제 nco-task MCP 호출은 CLI에서 불가하므로 /tmp/nco-l2-review.log에 기록만.

set -u

# 재진입 가드
if [ "${NCO_REVIEW_IN_PROGRESS:-0}" = "1" ]; then
  exit 0
fi

INPUT=$(cat 2>/dev/null)
FILE=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    ti = d.get('tool_input', {})
    fp = ti.get('file_path') or ti.get('notebook_path') or ''
    if not fp and isinstance(ti.get('edits'), list) and ti['edits']:
        fp = ti.get('file_path','')
    print(fp)
except: pass
" 2>/dev/null)

[ -z "$FILE" ] && exit 0

# 파일별 60초 lock (sha256 12자 prefix)
# R1-D (2026-05-27): mkdir로 atomic create-or-fail로 TOCTOU 해소.
# mkdir는 원자적 — 동시 두 프로세스 중 하나만 성공.
HASH=$(echo -n "$FILE" | sha256sum | cut -c1-12)
LOCK="/tmp/.nco-review-lock-$HASH"
# R2 (2026-05-27): rmdir-then-mkdir race window 제거 — mkdir 단일 시도만 사용.
# 60초 미만이면 자연스럽게 exit 0 (기존 lock dir 존재로 mkdir 실패).
# 60초 초과 stale lock은 외부 cleanup(cron/세션종료 trap)에 의존; 본 hook은
# atomic 보장 우선 — race window보다 가끔 stale 차단이 안전.
if [ -d "$LOCK" ]; then
  AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK" 2>/dev/null || date +%s) ))
  [ "$AGE" -lt 60 ] && exit 0
fi
# atomic acquire: mkdir 성공한 프로세스만 진행 (실패=race-lost 또는 stale)
if ! mkdir "$LOCK" 2>/dev/null; then
  exit 0
fi

# 백그라운드 리뷰 큐잉 (stub: 로그만 기록)
LOG="/tmp/nco-l2-review.log"
NCO_REVIEW_IN_PROGRESS=1 nohup bash -c \
  "echo \"[\$(date +%Y-%m-%dT%H:%M:%S)] L2 auto-review queued: $FILE\" >> '$LOG'" \
  >/dev/null 2>&1 &
disown 2>/dev/null

exit 0
