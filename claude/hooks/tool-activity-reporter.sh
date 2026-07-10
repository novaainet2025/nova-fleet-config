#!/usr/bin/env bash
# PreToolUse + PostToolUse Hook: 실시간 도구 활동을 NCO Dashboard에 리포트
# Read/Write/Edit/Bash/Glob/Grep 등의 도구 사용을 /api/activity로 전송
# 비동기(백그라운드) 실행 — 세션 속도에 영향 없음

NCO_API="${NCO_API_URL:-http://localhost:6200}"
# NCO_NAME 자동 탐지: /tmp/nco-names/claude-*.pid에서 조상 PID 매칭
if [ -z "$NCO_NAME" ] || [ "$NCO_NAME" = "unknown" ]; then
  # 조상 PID 체인 순회 (최대 5단계)
  _ck=$$
  for _ in 1 2 3 4 5; do
    _ck=$(ps -o ppid= -p "$_ck" 2>/dev/null | tr -d ' ')
    [ -z "$_ck" ] && break
    for _pf in /tmp/nco-names/claude-*.pid; do
      [ -f "$_pf" ] || continue
      [ "$(cat "$_pf" 2>/dev/null)" = "$_ck" ] && { NCO_NAME=$(basename "$_pf" .pid); break 2; }
    done
  done
fi
NCO_NAME="${NCO_NAME:-unknown}"
export NCO_NAME  # 필수: 아래 인라인 python POST가 os.environ에서 읽으므로 export 없으면 항상 'unknown'
HOOK_EVENT="${CLAUDE_HOOK_EVENT:-PreToolUse}"  # PreToolUse or PostToolUse

# stdin에서 JSON 파싱
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null)

# 도구명이 비어 있을 때만 스킵 — 그 외에는 어떤 도구든(ToolSearch/TaskOutput/Task/TodoWrite/
# Skill/mcp__* 등) 아래 fallback(else/*) 분기로 흘려보내 대시보드에 활동으로 보고한다.
# (이전엔 허용목록 없는 도구를 여기서 조기 종료시켜 실제 작업 중에도 대시보드가 idle로 보였음)
[ -z "$TOOL_NAME" ] && exit 0

# 파일 경로 / 명령 추출
FILE_PATH=$(echo "$INPUT" | python3 -c "
import json,sys
d = json.load(sys.stdin)
ti = d.get('tool_input', {}) or {}
tool = d.get('tool_name','')
if tool in ('Read','Write','Edit','MultiEdit','NotebookEdit'):
    print(ti.get('file_path', ti.get('path', '')))
elif tool in ('Glob',):
    print(ti.get('pattern', '') + ' @ ' + ti.get('path',''))
elif tool in ('Grep',):
    print(ti.get('pattern', '') + ' in ' + (ti.get('path','') or '.'))
elif tool in ('Bash',):
    cmd = ti.get('command','')
    print(cmd[:80] if cmd else '')
elif tool in ('WebFetch','WebSearch'):
    print(ti.get('url', ti.get('query', ''))[:80])
elif tool in ('ToolSearch',):
    print(ti.get('query','')[:80])
elif tool in ('Task','Agent'):
    print((ti.get('description') or ti.get('prompt',''))[:80])
elif tool in ('TodoWrite',):
    todos = ti.get('todos') or []
    print(f'{len(todos)} todos' if todos else '')
elif tool in ('Skill',):
    print(ti.get('skill', ''))
elif tool in ('TaskOutput','TaskGet','TaskStop','TaskUpdate'):
    print(ti.get('task_id', ti.get('id', '')))
else:
    print('')
" 2>/dev/null)

# 액션 타입 결정
case "$TOOL_NAME" in
  Read)           ACTION="reading" ;;
  Write)          ACTION="writing" ;;
  Edit|MultiEdit) ACTION="editing" ;;
  Bash)           ACTION="executing" ;;
  Glob)           ACTION="scanning" ;;
  Grep)           ACTION="searching" ;;
  WebFetch)       ACTION="fetching" ;;
  WebSearch)      ACTION="searching web" ;;
  NotebookEdit)   ACTION="editing notebook" ;;
  ToolSearch)     ACTION="searching tools" ;;
  Task|Agent)     ACTION="delegating" ;;
  TodoWrite)      ACTION="planning" ;;
  Skill)          ACTION="running skill" ;;
  TaskOutput|TaskGet|TaskStop|TaskUpdate) ACTION="checking task" ;;
  *)              ACTION="using $TOOL_NAME" ;;
esac

# 프로젝트명 추출 (파일 경로의 상위 디렉터리 기준)
PROJECT=""
if [ -n "$FILE_PATH" ] && [ "$TOOL_NAME" != "Bash" ]; then
  PROJECT=$(python3 -c "
import os, sys
fp = sys.argv[1]
if not fp or fp.startswith('searching') or fp.startswith('scanning'): sys.exit(0)
# /Users/nova-ai/project/nco-dashboard/src/... → nco-dashboard
parts = fp.split('/')
try:
    proj_idx = parts.index('project') + 1
    print(parts[proj_idx])
except:
    # 절대경로에서 2단계 상위 디렉터리
    try: print(os.path.basename(os.path.dirname(os.path.dirname(fp))))
    except: print('')
" "$FILE_PATH" 2>/dev/null)
fi

# CWD 기반 프로젝트 폴백
if [ -z "$PROJECT" ]; then
  PROJECT=$(basename "$(pwd)" 2>/dev/null)
fi

# PostToolUse의 경우 "done" 액션
if [ "$HOOK_EVENT" = "PostToolUse" ]; then
  ACTION="${ACTION}:done"
fi

# 비동기 POST — 대시보드가 없어도 실패해도 무시
{
  python3 -c "
import urllib.request, json, os, sys, socket
# NCO_NAME (claude-N) + 디바이스 prefix → inter-session 이름과 일치
nco_name = os.environ.get('NCO_NAME','unknown')
dev = socket.gethostname().lower().replace('.local','').replace('_','-')
# inter-session 이름: <device>-<claude-N>  (예: nova-macstudio-claude-2)
if nco_name and nco_name != 'unknown' and not nco_name.startswith(dev):
    session_name = f'{dev}-{nco_name}'
else:
    session_name = nco_name or 'unknown'
payload = {
  'session': session_name,
  'tool': sys.argv[1],
  'action': sys.argv[2],
  'file': sys.argv[3],
  'project': sys.argv[4],
  'event': os.environ.get('CLAUDE_HOOK_EVENT','PreToolUse'),
}
try:
  req = urllib.request.Request(
    'http://localhost:6200/api/activity',
    data=json.dumps(payload).encode(),
    headers={'Content-Type':'application/json'},
    method='POST'
  )
  urllib.request.urlopen(req, timeout=0.8)
except: pass
" "$TOOL_NAME" "$ACTION" "$FILE_PATH" "$PROJECT" 2>/dev/null
} &

exit 0
