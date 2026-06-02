#!/usr/bin/env bash
# higgsfield-auth-check.sh — Higgsfield CLI 인증 상태 확인
# exit 0: valid | exit 1: expired | exit 2: not installed

if ! command -v higgsfield >/dev/null 2>&1; then
  echo "not-installed"
  exit 2
fi

# token 명령으로 실제 토큰 존재 여부 확인 (auth status는 usage만 출력)
token=$(higgsfield auth token 2>/dev/null | tr -d '[:space:]')
if [[ -n "$token" && "$token" != *"Usage"* && "$token" != *"Error"* ]]; then
  echo "online"
  exit 0
fi

if command -v jq >/dev/null 2>&1; then
  expires=$(echo "$output" | jq -r '.token.expiresAt // .expiresAt // empty' 2>/dev/null)
  logged_in=$(echo "$output" | jq -r '.loggedIn // .authenticated // empty' 2>/dev/null)
else
  expires=$(echo "$output" | grep -oE '"expiresAt"\s*:\s*"[^"]+"' | cut -d'"' -f4)
  logged_in=$(echo "$output" | grep -oE '"loggedIn"\s*:\s*(true|false)' | grep -o 'true\|false')
fi

if [[ "$logged_in" == "true" ]] || echo "$output" | grep -qi "logged in\|authenticated"; then
  echo "online"
  exit 0
fi

if [[ -n "$expires" ]]; then
  expire_ts=$(date -d "$expires" +%s 2>/dev/null || echo 0)
  if (( expire_ts > 0 && expire_ts > $(date +%s) )); then
    echo "online"
    exit 0
  fi
fi

echo "auth-expired"
exit 1
