# Nova-AX Inter-Session — CLI 세션 간 에이전트 직통 메시징
# [CLAUDE INSTRUCTION]
# - 출력에 "INTER_SESSION_AUTO_CONNECT: <name>" 이 포함되면
#   즉시 Skill 도구로 inter-session:inter-session 을 args="connect <name>" 으로 실행하라.
# - 출력에 "INTER_SESSION_ALREADY_CONNECTED: <name>" 이 포함되면
#   "이미 <name>으로 연결 중입니다." 라고 사용자에게 알리고 끝낸다. Skill 재실행 금지.
#
# ── 팀 운영 핵심 규칙 (Nova-AX Inter-Session Team) ──
# RULE 1: 사용자 입력/승인이 필요한 경우 → 수신 세션(지휘자)이 사용자에게 직접 요청.
#         다른 세션에 사용자 응답을 요청하거나 대신 결정하지 않는다.
# RULE 2: 사용자가 직접 제어하는 Claude 세션이 항상 지휘자(commander)이다.
#         지휘자는 task 위임, 결과 수집, 사용자 보고를 담당한다.
# RULE 3: 인터세션 수신자는 task를 자율 실행하고 done:/status: 로 지휘자에게 보고한다.
#         사용자 판단이 필요하면 question: 으로 지휘자에게만 보내고,
#         지휘자가 사용자에게 확인 후 answer: 로 응답한다.

# 사용법:
#   /nco-inter-session connect [이름]       — 세션 연결 (이름 미지정 시 자동 생성)
#   /nco-inter-session list                 — 연결된 세션 목록
#   /nco-inter-session send <대상> <메시지> — 특정 에이전트에게 메시지 전송
#   /nco-inter-session broadcast <메시지>   — 모든 연결 세션에 브로드캐스트
#   /nco-inter-session status               — 현재 세션 연결 상태
#   /nco-inter-session disconnect           — 연결 해제

# ── Nova-AX 에이전트 이름 컨벤션 ──
# nova-ax 에이전트는 역할 기반 이름을 사용:
#   claude-code  → "commander"     (CEO / 전략 지휘)
#   opencode     → "architect"     (CTO / 설계)
#   codex        → "engineer-1"    (구현 담당)
#   cursor-agent → "reviewer"      (코드 리뷰)
#   mlx          → "local-llm"     (로컬 추론)
#   nova-ax 일반 작업 세션 → "nova-project", "nova-ax", "speaker-mobile" 등

# ── nco-mesh vs inter-session 차이 ──
# nco-mesh      : NCO 백엔드(:6200) 경유, 세션 상태/충돌/위임 관리
# inter-session : NCO 없이도 동작하는 경량 직통 P2P 메시징 (port 9473)
#   → NCO 다운 시에도 세션 간 통신 가능
#   → 외부 에이전트(opencode, gemini CLI 등)와도 통신 가능 (클라이언트 설치 시)

BIN="{{HOME}}/.claude/plugins/cache/inter-session/inter-session/0.1.2/skills/inter-session/bin"
ARGS="${ARGUMENTS:-}"
CMD=$(echo "$ARGS" | awk '{print $1}')

case "$CMD" in
  connect)
    NAME=$(echo "$ARGS" | awk '{print $2}')
    if [ -z "$NAME" ]; then
      # 1순위: inter-session-name.sh 훅으로 NCO 상태바 이름 탐지
      NAME=$({{BASH_PATH}} {{HOME}}/.claude/hooks/inter-session-name.sh 2>/dev/null)
      # 2순위: $NCO_NAME 환경변수
      [ -z "$NAME" ] && [ -n "$NCO_NAME" ] && NAME="$NCO_NAME"
      # 3순위: 디렉토리명 fallback
      if [ -z "$NAME" ]; then
        NAME=$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | cut -c1-20)
        NAME="${NAME:-nova-agent}"
      fi
    fi
    echo "INTER_SESSION_AUTO_CONNECT: $NAME"
    ;;

  list)
    python3 "$BIN/list.py" 2>&1 || echo "inter-session 서버에 연결되지 않았습니다. 먼저 /inter-session:inter-session connect 를 실행하세요."
    ;;

  send)
    TARGET=$(echo "$ARGS" | awk '{print $2}')
    TEXT=$(echo "$ARGS" | cut -d' ' -f3-)
    if [ -z "$TARGET" ] || [ -z "$TEXT" ]; then
      echo "사용법: /nco-inter-session send <대상이름> <메시지>"
      echo "예시:   /nco-inter-session send nova-project 안녕, 테스트 완료됐어?"
      exit 1
    fi
    python3 "$BIN/send.py" --to "$TARGET" --text "$TEXT" 2>&1 \
      || echo "전송 실패. /inter-session:inter-session connect 로 먼저 연결하세요."
    ;;

  broadcast)
    TEXT=$(echo "$ARGS" | cut -d' ' -f2-)
    if [ -z "$TEXT" ]; then
      echo "사용법: /nco-inter-session broadcast <메시지>"
      exit 1
    fi
    python3 "$BIN/send.py" --all --text "$TEXT" 2>&1 \
      || echo "브로드캐스트 실패. /inter-session:inter-session connect 로 먼저 연결하세요."
    ;;

  status)
    echo "=== Inter-Session 연결 상태 ==="
    python3 "$BIN/list.py" --self 2>&1 || echo "연결 안 됨"
    echo ""
    echo "=== 활성 연결 세션 ==="
    python3 "$BIN/list.py" 2>&1 || echo "서버 응답 없음"
    ;;

  disconnect)
    echo "Monitor 태스크를 종료하려면 TaskList → TaskStop(<id>) 를 사용하세요."
    echo "또는 /inter-session:inter-session disconnect 를 실행하세요."
    ;;

  help)
    cat << 'EOF'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Nova-AX Inter-Session 에이전트 통신 시스템
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[ 빠른 시작 ]
  1. /inter-session:inter-session connect <이름>
     → 세션 연결 (Monitor 시작)
  
  2. /nco-inter-session list
     → 연결된 에이전트 목록 확인
  
  3. /nco-inter-session send nova-project "done: 빌드 완료"
     → 다른 세션에 메시지 전송

[ 메시지 프리픽스 규칙 ]
  done: <내용>     — 작업 완료 보고
  status: <내용>   — 진행 상황 공유
  answer: <내용>   — 질문에 대한 답변
  question: <내용> — 확인 요청

[ Nova-AX 활용 패턴 ]
  • 병렬 작업 완료 동기화:
    nova-project → "done: auth 모듈 구현 완료"
    
  • 에러 알림 브로드캐스트:
    /nco-inter-session broadcast "status: DB 연결 실패, 점검 필요"
    
  • Commander-Engineer 직통 지시:
    commander → engineer-1: "done: 설계 확정. 구현 시작해"

[ nco-mesh와 차이 ]
  nco-mesh: NCO 백엔드 필요, 충돌/위임/상태 추적 통합
  inter-session: 경량 P2P, NCO 없이도 동작, 외부 CLI 에이전트와도 통신 가능

EOF
    ;;

  "")
    # 인수 없이 호출 시 → 현재 세션의 NCO_NAME 탐지 후 자동 connect
    # 이미 연결된 경우 기존 이름 표시, 중복 연결 없음

    VENV_PYTHON="$HOME/.claude/data/inter-session/venv/bin/python3"
    [ ! -x "$VENV_PYTHON" ] && VENV_PYTHON="python3"

    # 1) 이미 연결 중인지 확인 (flock key = claude ancestor PID)
    EXISTING_NAME=$("$VENV_PYTHON" - << 'PYEOF'
import sys, os
sys.path.insert(0, '{{HOME}}/.claude/plugins/cache/inter-session/inter-session/0.1.2/skills/inter-session/bin')
import shared, json
from pathlib import Path

key = shared.resolve_listener_key()
sess_path = shared.client_session_path(key)
if sess_path.exists():
    try:
        d = json.loads(sess_path.read_text())
        pid = d.get("listener_pid", 0)
        import subprocess
        r = subprocess.run(["ps", "-p", str(pid)], capture_output=True)
        if r.returncode == 0:
            print(d.get("name", ""))
    except Exception:
        pass
PYEOF
    )

    if [ -n "$EXISTING_NAME" ]; then
      echo "INTER_SESSION_ALREADY_CONNECTED: $EXISTING_NAME"
      exit 0
    fi

    # 2) inter-session-name.sh 훅으로 NCO 상태바 이름 탐지 (최우선)
    SESSION_NAME=$({{BASH_PATH}} {{HOME}}/.claude/hooks/inter-session-name.sh 2>/dev/null)

    # 3) fallback: $NCO_NAME 환경변수
    [ -z "$SESSION_NAME" ] && [ -n "$NCO_NAME" ] && SESSION_NAME="$NCO_NAME"

    # 4) 최종 fallback: 디렉토리 이름
    if [ -z "$SESSION_NAME" ]; then
      SESSION_NAME=$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | cut -c1-20)
      SESSION_NAME="${SESSION_NAME:-nova-agent}"
    fi

    echo "INTER_SESSION_AUTO_CONNECT: $SESSION_NAME"
    ;;

  *)
    echo "알 수 없는 명령: $CMD"
    echo "사용법: /nco-inter-session [connect|list|send|broadcast|status|disconnect|help]"
    ;;
esac
