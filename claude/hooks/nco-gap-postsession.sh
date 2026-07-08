#!/bin/bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작 (2026-07-08, 76s 훅스택+BOOTSTRAP 오염 T1)
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
# Stop 훅 (백그라운드): 세션 종료 후 변경 파일에 대해 비차단 Gap 분석
# 디자인:
#   - Stop 훅을 블로킹하지 않음 (백그라운드 spawn 후 즉시 exit 0)
#   - 변경 파일이 없으면 스킵
#   - NCO로 nco-task cursor-agent (실패 시 nvidia) 호출 → 결과를 로그에 기록
#   - 다음 SessionStart의 improvement-inject가 이 로그를 픽업해서 컨텍스트로 주입
#
# 기존 Stop 훅의 advisor-stop·memory-snapshot과 별도로 동작.
# 자동 재시도 5회 루프는 일부러 미포함 — 비용·시간·NCO 안정성 우려. 사용자가 결과 보고 수동 결정.
#
# 비활성화: NCO_AUTO_GAP=0 환경변수

[ "${NCO_AUTO_GAP:-1}" = "0" ] && exit 0

INPUT=$(cat 2>/dev/null)
PERF_DIR="{{HOME}}/.claude/nco-perf"
mkdir -p "$PERF_DIR" 2>/dev/null

# 세션 ID
if [ -z "$NCO_SESSION_ID" ]; then
    _CK=$$
    for _i in 1 2 3 4 5; do
        _CK=$(ps -o ppid= -p "$_CK" 2>/dev/null | tr -d ' ')
        [ -z "$_CK" ] && break
        _CM=$(ps -o comm= -p "$_CK" 2>/dev/null)
        echo "$_CM" | grep -qE '^(claude|node)$' && { NCO_SESSION_ID="$_CK"; break; }
    done
    NCO_SESSION_ID="${NCO_SESSION_ID:-$$}"
fi

GAP_LOG="$PERF_DIR/gap-${NCO_SESSION_ID}.json"
GAP_RUN_FLAG="/tmp/nco-gap-running-${NCO_SESSION_ID}.lock"

# 이미 실행 중이면 스킵 (이중 호출 방지)
[ -f "$GAP_RUN_FLAG" ] && exit 0
touch "$GAP_RUN_FLAG" 2>/dev/null

# 변경 파일 수집 (project_dir + 최근 5분 mtime)
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
CHANGED=$(git -C "$PROJECT_DIR" diff --name-only HEAD 2>/dev/null | head -20)
if [ -z "$CHANGED" ]; then
    rm -f "$GAP_RUN_FLAG"
    exit 0
fi

# NCO 헬스 확인 (다운이면 스킵)
curl -s -m 2 http://localhost:6200/health 2>/dev/null | grep -q '"status":"healthy"' || {
    rm -f "$GAP_RUN_FLAG"
    exit 0
}

# 동일 변경셋 반복 발행 게이트 (2026-07-08): nco 저장소 상시 dirty(수백 파일) 환경에서
# 매 Stop마다 같은 Gap 분석이 재발행돼 로컬 워커 큐를 침수시킴(hermes 10건 적체 실측).
# 변경셋 해시가 직전과 같으면 6시간 쿨다운 — 내용이 실제로 바뀌면 즉시 재분석.
# 해시 파일은 세션 공유(전 세션 dedup 목적).
GAP_HASH=$(echo "$CHANGED" | shasum -a 256 2>/dev/null | cut -d' ' -f1)
GAP_HASH_FILE="$PERF_DIR/gap-last-hash"
if [ -n "$GAP_HASH" ] && [ -f "$GAP_HASH_FILE" ]; then
    read -r _lh _lt < "$GAP_HASH_FILE" 2>/dev/null
    _age=$(( $(date +%s) - ${_lt:-0} ))
    if [ "$_lh" = "$GAP_HASH" ] && [ "$_age" -lt 21600 ]; then
        rm -f "$GAP_RUN_FLAG"
        exit 0
    fi
fi
[ -n "$GAP_HASH" ] && printf '%s %s' "$GAP_HASH" "$(date +%s)" > "$GAP_HASH_FILE" 2>/dev/null

# 백그라운드로 Gap 분석 발행 — Stop 훅이 블로킹되지 않도록
# 변수는 서브쉘 fork 시점에 그대로 상속됨 (single quote 회피 위해 subshell 사용)
# disown으로 부모 jobs 테이블에서 제거 → 부모 종료해도 SIGHUP 안 받음
(
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    CHANGED_LIST=$(echo "$CHANGED" | tr '\n' ' ' | head -c 1500)

    # 리밋(gate.available===false) 프로바이더는 건너뛴다 — gated에 배정하면 확정 실패
    # (사용자 지적 + ERR-013 단일 SoT: cursor-agent/nvidia 등 리밋 시 codex 등 가용으로 직행)
    _GAP_AGENTS=$(curl -s -m 2 http://localhost:6200/api/agents 2>/dev/null)
    # cursor-agent(리뷰어) 우선, gated면 skip → 무료 로컬 워커(ollama/hermes) 우선, 최후에만 유료 codex
    # (사용자 directive "워커=무료 로컬 우선" + tier-policy quality=[cursor-agent,ollama,nvidia])
    for AI in cursor-agent ollama hermes nvidia codex; do
        if printf '%s' "$_GAP_AGENTS" | python3 -c "
import json,sys
# 안정적 가용(available===True AND circuit==closed)일 때만 시도, 그 외엔 skip.
# fail-closed: API 이상/미발견/half-open flapping/gated 모두 skip → gated 배정 확정 차단 (ERR-013).
try:
    d=json.load(sys.stdin); a=[x for x in d.get('agents',[]) if x.get('id')==sys.argv[1]]
    if not a: sys.exit(0)  # 못 찾음(API 이상) → skip
    g=a[0].get('gate') or {}; h=a[0].get('health') or {}
    ok=(g.get('available') is True) and (h.get('circuitState')=='closed')
    sys.exit(1 if ok else 0)  # exit0=skip
except Exception: sys.exit(0)  # 파싱 실패 → skip(fail-closed)
" "$AI" 2>/dev/null; then continue; fi
        RESP=$(curl -s -m 90 -X POST http://localhost:6200/api/task \
            -H 'Content-Type: application/json' \
            -d "$(python3 -c "import json,sys; print(json.dumps({
                'ai': sys.argv[1],
                'prompt': 'Gap analysis: 다음 변경 파일에 대해 (1) 빠진 테스트 (2) 잠재 버그 (3) 보안 이슈 (4) 점수 0-100 을 간결히 보고. 응답 형식: SCORE:<n> · ISSUES:<list>. 파일: ' + sys.argv[2]
            }))" "$AI" "$CHANGED_LIST")" 2>/dev/null)

        if echo "$RESP" | grep -q '"taskId"'; then
            TID=$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('taskId',''))" 2>/dev/null)
            # 최대 90초 폴링
            for i in $(seq 1 30); do
                sleep 3
                STATUS=$(curl -s -m 5 "http://localhost:6200/api/tasks?taskId=${TID}" 2>/dev/null \
                  | python3 -c "import json,sys
try:
 d=json.load(sys.stdin)
 t=[x for x in d.get('tasks',[]) if x['id']=='${TID}']
 if t: print(t[0].get('status',''),'|',(t[0].get('response') or '')[:2000])
except: pass" 2>/dev/null)
                echo "$STATUS" | grep -q '^completed' && break
            done

            if [ -n "$STATUS" ]; then
                python3 -c "
import json, time
now = '$NOW'
ai = '$AI'
status_line = '''$STATUS'''
score = 0
import re
m = re.search(r'SCORE:\s*(\d+)', status_line)
if m: score = int(m.group(1))
data = {
    'session_id': '$NCO_SESSION_ID',
    'ts': now,
    'ai': ai,
    'changed_files': '$CHANGED_LIST'.split()[:20],
    'response_excerpt': status_line[:1500],
    'score': score,
    'pass': score >= 90,
}
json.dump(data, open('$GAP_LOG','w'), ensure_ascii=False, indent=2)
" 2>/dev/null
                break  # 한 번 성공하면 다음 AI 시도 안 함
            fi
        fi
    done

    rm -f "$GAP_RUN_FLAG"
) </dev/null >/dev/null 2>&1 &

# 백그라운드 PID 기록 + disown으로 부모 jobs 테이블에서 제거 (SIGHUP 격리)
BG_PID=$!
echo $BG_PID > "/tmp/nco-gap-pid-${NCO_SESSION_ID}" 2>/dev/null
disown $BG_PID 2>/dev/null || true

exit 0
