#!/usr/bin/env bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작 (2026-07-08, 76s 훅스택+BOOTSTRAP 오염 T1)
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
set -euo pipefail

SELF_PATH="/tmp/secret-exfil-guard.sh"

json_input="$(cat)"

extract_json_field() {
  local expr="$1"
  JSON_INPUT="$json_input" python3 - "$expr" <<'PY'
import json
import os
import sys

expr = sys.argv[1]
raw = os.environ.get("JSON_INPUT", "")
try:
    data = json.loads(raw or "{}")
except Exception:
    print("")
    raise SystemExit(0)

value = data
for part in expr.split("."):
    if isinstance(value, dict):
        value = value.get(part, "")
    else:
        value = ""
        break

if value is None:
    value = ""
elif not isinstance(value, str):
    value = str(value)

print(value)
PY
}

contains_real_secret() {
  local value="$1"
  [[ "$value" =~ sk-[A-Za-z0-9]{20,} ]] && return 0
  [[ "$value" =~ AIza[0-9A-Za-z_-]{30,} ]] && return 0
  [[ "$value" =~ sk-ant-[A-Za-z0-9_-]{10,} ]] && return 0
  [[ "$value" =~ sk-or-v1-[A-Za-z0-9_-]{10,} ]] && return 0
  return 1
}

path_is_relaxed() {
  local path_value="$1"
  [[ "$path_value" =~ (^|/)(example|sample|test)(/|$|[^[:alnum:]_]) ]] || [[ "$path_value" =~ [Ee][Xx][Aa][Mm][Pp][Ll][Ee]|[Ss][Aa][Mm][Pp][Ll][Ee]|[Tt][Ee][Ss][Tt] ]]
}

is_local_curl_command() {
  local command="$1"
  [[ "$command" =~ curl[^$'\n']*(localhost|127\.0\.0\.1) ]]
}

tool_name="$(extract_json_field "tool_name")"
file_path="$(extract_json_field "tool_input.file_path")"
content="$(extract_json_field "tool_input.content")"
new_string="$(extract_json_field "tool_input.new_string")"
command="$(extract_json_field "tool_input.command")"

if [[ "$tool_name" == "Write" || "$tool_name" == "Edit" ]]; then
  if [[ "$file_path" == "$SELF_PATH" ]]; then
    exit 0
  fi

  if ! path_is_relaxed "$file_path"; then
    if contains_real_secret "$content"; then
      echo "blocked: refusing to write apparent live secret material to file" >&2
      exit 2
    fi
    if contains_real_secret "$new_string"; then
      echo "blocked: refusing to edit apparent live secret material into file" >&2
      exit 2
    fi
  fi
fi

if [[ "$tool_name" == "Bash" ]]; then
  if [[ "$command" == *"$SELF_PATH"* ]]; then
    exit 0
  fi

  local_curl_allowed=1
  if is_local_curl_command "$command"; then
    local_curl_allowed=0
  fi

  if [[ "$local_curl_allowed" -ne 0 ]] && [[ "$command" =~ (transcript|messages\.log|conversation) ]] && [[ "$command" =~ (send\.py[^$'\n']*--all|broadcast|api/mesh/send) ]]; then
    echo "blocked: refusing to broadcast conversation artifacts externally" >&2
    exit 2
  fi

  if [[ "$command" =~ (^|[^[:alnum:]_])(env|printenv)([^[:alnum:]_]|$) ]]; then
    if [[ "$command" =~ curl[^$'\n']*(-d|--data|--data-raw|--data-binary) ]]; then
      if ! is_local_curl_command "$command"; then
        echo "blocked: refusing to exfiltrate environment variables via curl payload" >&2
        exit 2
      fi
    fi

    if [[ "$command" =~ (send\.py|broadcast) ]] || { [[ "$command" =~ api/mesh/send ]] && [[ "$local_curl_allowed" -ne 0 ]]; }; then
      echo "blocked: refusing to exfiltrate environment variables via external send" >&2
      exit 2
    fi
  fi
fi

exit 0
