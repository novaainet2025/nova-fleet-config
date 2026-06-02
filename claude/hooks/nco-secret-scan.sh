#!/bin/bash
# PreToolUse: NCO 위임 시 시크릿(API키/토큰/.env) 유출 차단
# nco-task / nco-team / nco-parallel / nco-discussion / nco-consensus 등 외부 AI에 데이터를 보내는 호출에서
# 프롬프트 또는 인자 안에 시크릿 패턴이 발견되면 차단.
# exit 0 = 허용 | exit 2 = 차단 (stderr → Claude system reminder)

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | python3 -c "
import sys, json
try: print(json.load(sys.stdin).get('tool_name',''))
except: print('')
" 2>/dev/null)

# NCO 위임 도구만 감시
case "$TOOL_NAME" in
    mcp__nco-commands__*) ;;
    nco_task|nco_parallel|nco_team|nco_discussion|nco_consensus|nco_commander|nco_conductor|nco_hive|nco_collab) ;;
    Skill)
        SKILL_NAME=$(echo "$INPUT" | python3 -c "
import sys, json
try: print(json.load(sys.stdin).get('tool_input',{}).get('skill',''))
except: print('')
" 2>/dev/null)
        echo "$SKILL_NAME" | grep -qE '^nco-' || exit 0
        ;;
    *) exit 0 ;;
esac

# 프롬프트/인자 전체 텍스트 추출
PAYLOAD=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    ti = d.get('tool_input', {})
    parts = []
    for k in ('prompt','arguments','args','message','content','question','topic'):
        v = ti.get(k)
        if isinstance(v, str): parts.append(v)
        elif isinstance(v, (list,dict)): parts.append(json.dumps(v, ensure_ascii=False))
    print('\n'.join(parts))
except: print('')
" 2>/dev/null)

[ -z "$PAYLOAD" ] && exit 0

# Unicode 정규화 + zero-width 제거 (\uXXXX 회피용 unicode_escape는 한글 깨뜨려서 제외)
# \uXXXX 패턴이 명시적으로 있으면 그것만 별도 디코드
PAYLOAD=$(printf '%s' "$PAYLOAD" | python3 -c "
import sys, unicodedata, re
s = sys.stdin.read()
try: s = unicodedata.normalize('NFKC', s)
except: pass
# \\uXXXX 형식이 있으면 그 부분만 디코드 (한글 보존)
def _decode(m):
    try: return chr(int(m.group(1), 16))
    except: return m.group(0)
s = re.sub(r'\\\\u([0-9a-fA-F]{4})', _decode, s)
# zero-width 제거
for zw in ('​','‌','‍','﻿'):
    s = s.replace(zw, '')
sys.stdout.write(s)
" 2>/dev/null) || PAYLOAD="$PAYLOAD"

# 시크릿 패턴 (보수적: 명백한 키 포맷만) + 한국어 라벨 추가
HIT=$(echo "$PAYLOAD" | grep -oE \
    -e 'sk-[A-Za-z0-9_-]{20,}' \
    -e 'sk-ant-[A-Za-z0-9_-]{30,}' \
    -e 'AKIA[0-9A-Z]{16}' \
    -e 'AIza[0-9A-Za-z_-]{35}' \
    -e 'ghp_[A-Za-z0-9]{30,}' \
    -e 'ghs_[A-Za-z0-9]{30,}' \
    -e 'gho_[A-Za-z0-9]{30,}' \
    -e 'glpat-[A-Za-z0-9_-]{20,}' \
    -e 'nvapi-[A-Za-z0-9_-]{30,}' \
    -e 'xox[abprs]-[A-Za-z0-9-]{10,}' \
    -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
    -e 'eyJ[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{30,}' \
    -e '(password|passwd|secret|api_key|apikey|token|비밀번호|암호|토큰|비밀키|개인키)["'\''=: ]+[A-Za-z0-9_!@#$%^&*-]{16,}' \
    2>/dev/null | head -3)

if [ -n "$HIT" ]; then
    # 첫 토큰만 마스킹해서 로그
    MASKED=$(echo "$HIT" | head -1 | sed -E 's/(.{4}).*(.{4})/\1***\2/')
    cat >&2 <<MSG
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[NCO 시크릿 가드 — 위임 차단]

⛔ 외부 AI로 보내려는 프롬프트에서 시크릿 패턴 감지: ${MASKED}

규칙: NCO 위임 시 API키·토큰·비밀번호·.env 내용을 직접 인용 금지.
조치:
  1. 시크릿을 \$VAR 환경변수 참조로 바꿔서 다시 호출
  2. 시크릿 파일 경로만 전달하고 내용은 워커가 로컬에서 읽도록
  3. 정말 필요하면 NCO_SECRET_SCAN=0 으로 임시 해제 (강력 비권장)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
MSG
    [ "${NCO_SECRET_SCAN:-1}" = "0" ] && exit 0
    exit 2
fi

exit 0
