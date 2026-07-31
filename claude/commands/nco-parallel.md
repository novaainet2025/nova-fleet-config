# 여러 AI에 동일 작업을 병렬로 위임합니다.
#
# 사용법:
#   /nco-parallel <프롬프트>                    — 기본 프로바이더로 병렬 실행
#   /nco-parallel [codex, agy] <프롬프트>       — 프로바이더 지정 (대괄호 형식)
#   /nco-parallel codex,agy <프롬프트>          — 프로바이더 지정 (쉼표 형식)
#
# 2026-07-29 신규: CLAUDE.md 와 nco-collab-inject.sh 등 훅 10곳 이상이
# `/nco-parallel [codex, agy] "..."` 를 안내하고 있었으나 커맨드 파일이
# 어느 경로에도 존재하지 않았다(글로벌·프로젝트·fleet 전부 부재).
# 서버의 POST /api/parallel 은 실재하므로 그 위에 얹는다.
# 스키마: {prompt: string(1+), providers: string[](1+)} — 둘 다 필수.

BASE="http://localhost:6200"
_ARGS="$ARGUMENTS"

if [ -z "$_ARGS" ]; then
  echo "사용법: /nco-parallel [codex, agy] <프롬프트>"
  echo "       /nco-parallel <프롬프트>          (기본 프로바이더 사용)"
  exit 1
fi

PROVIDERS=""
PROMPT="$_ARGS"

# 실제 등록된 프로바이더 목록 (프로바이더 지정인지 프롬프트인지 판별에 사용).
# 서버가 안 뜬 경우를 대비해 빈 값이면 판별을 건너뛰고 전체를 프롬프트로 본다.
KNOWN=$(curl -s -m 5 http://localhost:6200/api/ai-providers 2>/dev/null \
  | python3 -c "import sys,json
try: print(' '.join(p['id'] for p in json.load(sys.stdin).get('providers',[])))
except Exception: print('')" 2>/dev/null)

# 프로바이더 접두부만 떼어내고 프롬프트 본문은 원본 그대로 둔다.
# 이전 판은 입력 전체에 쉼표 정규화를 걸어서
# '[codex, agy] Compare A, B and C, D' 의 프롬프트가 'Compare A,B and C,D' 로
# 변조돼 AI 에 원문과 다른 문장이 전달됐다. 정규화는 접두부에만 적용한다.

case "$_ARGS" in
  \[*\]*)
    PROVIDERS=$(printf '%s' "$_ARGS" | sed -E 's/^\[([^]]*)\].*/\1/' | sed -E 's/[[:space:]]*,[[:space:]]*/,/g; s/^[[:space:]]+|[[:space:]]+$//g')
    PROMPT=$(printf '%s' "$_ARGS" | sed -E 's/^\[[^]]*\][[:space:]]*//')
    ;;
  *)
    # 'codex,agy <프롬프트>' / 'codex, agy <프롬프트>' 형식.
    # 쉼표를 하나 이상 포함한 선행 이름 목록만 매칭한다(단일 이름은 프롬프트로 본다).
    _PFX=$(printf '%s' "$_ARGS" | sed -nE 's/^([A-Za-z0-9_-]+([[:space:]]*,[[:space:]]*[A-Za-z0-9_-]+)+)[[:space:]]+.*$/\1/p')
    if [ -n "$_PFX" ]; then
      _CAND=$(printf '%s' "$_PFX" | sed -E 's/[[:space:]]*,[[:space:]]*/,/g')
      # 쉼표가 있다고 무조건 프로바이더로 보면 "안녕, 세계" 같은 프롬프트를 오인한다.
      # 모든 항목이 실제 등록된 프로바이더일 때만 프로바이더 지정으로 판정한다.
      ALL_KNOWN=yes
      if [ -n "$KNOWN" ]; then
        for p in $(printf '%s' "$_CAND" | tr ',' ' '); do
          case " $KNOWN " in *" $p "*) ;; *) ALL_KNOWN=no ;; esac
        done
      else
        ALL_KNOWN=no
      fi
      if [ "$ALL_KNOWN" = yes ]; then
        PROVIDERS="$_CAND"
        # 접두부 길이만큼만 잘라내고 나머지는 원본 그대로 — 프롬프트를 건드리지 않는다.
        PROMPT=$(PFX="$_PFX" ARGS="$_ARGS" python3 -c '
import os
a=os.environ["ARGS"]; p=os.environ["PFX"]
print(a[len(p):].lstrip())')
      else
        echo "[안내] '$_CAND' 를 프로바이더 목록으로 해석하지 않았습니다(등록되지 않은 이름 포함)."
        echo "       프로바이더를 지정하려면 대괄호 형식을 쓰세요: /nco-parallel [codex, agy] <프롬프트>"
        echo "       등록된 프로바이더: ${KNOWN:-(조회 실패)}"
      fi
    fi
    ;;
esac

if [ -z "$PROMPT" ]; then
  echo "[오류] 프롬프트가 비어 있습니다."
  exit 1
fi

# 프로바이더 미지정이면 기본값을 쓴다.
# 기본값 배정을 검증보다 먼저 한다 — 이전 판은 검증 뒤에 배정해서
# 기본값이 비활성/미등록 프로바이더를 가리켜도 그대로 서버로 나갔다.
if [ -z "$PROVIDERS" ]; then
  PROVIDERS="codex,agy"
fi

# 최종 검증 — 명시 지정이든 기본값이든 서버에 실제로 등록된 이름인지 확인한다.
# 등록 목록은 오버레이(ai-providers.local.json) 병합 후의 런타임 값이므로
# base config 만 보고 판단하면 안 된다.
if [ -n "$KNOWN" ]; then
  for p in $(printf '%s' "$PROVIDERS" | tr ',' ' '); do
    case " $KNOWN " in
      *" $p "*) ;;
      *) echo "[오류] 등록되지 않았거나 비활성인 프로바이더: $p"
         echo "       등록된 프로바이더: $KNOWN"
         exit 1 ;;
    esac
  done
else
  echo "[경고] 프로바이더 목록을 조회하지 못했습니다(NCO 미응답). 검증 없이 진행합니다."
fi

PAYLOAD=$(PROVIDERS="$PROVIDERS" PROMPT="$PROMPT" python3 -c '
import json, os
providers = [p.strip() for p in os.environ["PROVIDERS"].replace(" ", ",").split(",") if p.strip()]
print(json.dumps({"prompt": os.environ["PROMPT"].strip(), "providers": providers}))
')

echo "[NCO 병렬 실행] providers=$PROVIDERS"
printf '%s' "$PAYLOAD" \
  | curl -s -X POST "$BASE/api/parallel" \
      -H "Content-Type: application/json" \
      --data-binary @- \
  | python3 -m json.tool 2>/dev/null \
  || echo "[오류] NCO 서버 응답 없음 (또는 응답이 JSON이 아님)."
