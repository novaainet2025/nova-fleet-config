#!/usr/bin/env bash
# verify.sh — 프로바이더 공통 결과 검증 스크립트 (T1 증거 수집기)
# 어떤 프로바이더(codex/agy/opencode/cursor/ollama/claude)든 shell 하나로 호출 가능.
# 훅 체계에 의존하지 않으므로 프로바이더가 바뀌어도 하네스가 깨지지 않는다.
#
# 사용:
#   verify.sh --file PATH               # 파일 존재+비어있지않음 (T1)
#   verify.sh --grep 'PATTERN::FILE'    # 파일 내 문자열 존재 (T1)
#   verify.sh --http URL[::EXPECT]      # HTTP 200 (+본문에 EXPECT 포함) (T1)
#   verify.sh --port N                  # 포트 점유 (T2)
#   verify.sh --cmd 'SHELL'             # 명령 exit 0 (T3)
#   ...여러 개 조합 가능. 하나라도 실패 시 exit 1 (루프 엔진 재작업 트리거).
#
# 출력: 각 검사의 [등급]/[결과] + 종합 검증 영수증. 결과는 JSON도 함께(--json).

set -u
PASS=0; FAIL=0; JSON=0; LINES=(); JROWS=()
_ok(){ PASS=$((PASS+1)); LINES+=("  ✓ [$1] $2"); JROWS+=("{\"tier\":\"$1\",\"ok\":true,\"detail\":\"$3\"}"); }
_no(){ FAIL=$((FAIL+1)); LINES+=("  ✗ [$1] $2"); JROWS+=("{\"tier\":\"$1\",\"ok\":false,\"detail\":\"$3\"}"); }

while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift ;;
    --file)
      f="$2"; shift 2
      if [ -s "$f" ]; then _ok T1 "file exists+nonempty: $f" "$f"; else _no T1 "file missing/empty: $f" "$f"; fi ;;
    --grep)
      spec="$2"; shift 2; pat="${spec%%::*}"; file="${spec##*::}"
      if [ -f "$file" ] && grep -q -- "$pat" "$file" 2>/dev/null; then _ok T1 "grep '$pat' in $file" "$pat"; else _no T1 "grep '$pat' NOT in $file" "$pat"; fi ;;
    --http)
      spec="$2"; shift 2; url="${spec%%::*}"; expect=""; [ "$spec" != "$url" ] && expect="${spec##*::}"
      body=$(curl -s --max-time 10 -w '\n%{http_code}' "$url" 2>/dev/null); code=$(printf '%s' "$body" | tail -1); body=$(printf '%s' "$body" | sed '$d')
      if [ "$code" = "200" ]; then
        if [ -z "$expect" ] || printf '%s' "$body" | grep -q -- "$expect"; then _ok T1 "HTTP 200 $url ${expect:+(body~$expect)}" "$url"; else _no T1 "HTTP 200 but body lacks '$expect': $url" "$url"; fi
      else _no T1 "HTTP $code (!=200): $url" "$url"; fi ;;
    --port)
      p="$2"; shift 2
      if lsof -iTCP:"$p" -sTCP:LISTEN -n -P >/dev/null 2>&1 || nc -z localhost "$p" >/dev/null 2>&1; then _ok T2 "port $p listening" "$p"; else _no T2 "port $p not listening" "$p"; fi ;;
    --cmd)
      c="$2"; shift 2
      if eval "$c" >/dev/null 2>&1; then _ok T3 "cmd exit0: $c" "$c"; else _no T3 "cmd nonzero: $c" "$c"; fi ;;
    *) echo "unknown arg: $1" >&2; shift ;;
  esac
done

TOTAL=$((PASS+FAIL))
if [ "$JSON" = "1" ]; then
  IFS=,; echo "{\"pass\":$PASS,\"fail\":$FAIL,\"total\":$TOTAL,\"ok\":$([ $FAIL -eq 0 ] && echo true || echo false),\"checks\":[${JROWS[*]:-}]}"; unset IFS
else
  echo "## 검증 영수증 (verify.sh)"
  printf '%s\n' "${LINES[@]:-  (검사 없음)}"
  echo "- [종합] $PASS/$TOTAL PASS · Gap $([ $TOTAL -gt 0 ] && python3 -c "print(f'{100*$PASS/$TOTAL:.0f}%')" || echo 'n/a')"
  echo "- [판정] $([ $FAIL -eq 0 ] && echo '✅ 전부 통과 → 완료 가능' || echo '❌ 미달 → 루프 엔진 재작업 필요')"
fi
[ $FAIL -eq 0 ] && exit 0 || exit 1
