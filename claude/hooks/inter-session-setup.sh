#!/usr/bin/env bash
# inter-session Tailscale setup wizard
# - 현재 머신의 Tailscale IPv4 자동 감지
# - 토큰 파일 권한·내용 검증
# - 호스트(server) / 클라이언트(peer) 두 시나리오의 실행 명령 출력
# - 토큰 전송 안내 (수동 + tailscale file copy)
#
# 사용:
#   bash ~/.claude/hooks/inter-session-setup.sh          # 호스트 모드 (이 머신이 서버)
#   bash ~/.claude/hooks/inter-session-setup.sh client   # 클라이언트 모드 (피어 머신에 연결)
#
# 정책:
#   - 코드 패치 없음 (inter-session은 env 변수만으로 외부 노출 가능)
#   - 토큰은 host에서만 생성 → peer로 수동 복사 (over-engineering 회피)
#   - WSS 미사용 (Tailscale WireGuard로 이미 E2E 암호화)

set -u

C_RED='\033[0;31m'
C_GRN='\033[0;32m'
C_YLW='\033[0;33m'
C_CYN='\033[0;36m'
C_BLD='\033[1m'
C_RST='\033[0m'

DATA_DIR="${HOME}/.claude/data/inter-session"
TOKEN_FILE="${DATA_DIR}/token"
DEFAULT_PORT=9473

err()  { printf "${C_RED}✗${C_RST} %b\n" "$*" >&2; }
warn() { printf "${C_YLW}!${C_RST} %b\n" "$*"; }
ok()   { printf "${C_GRN}✓${C_RST} %b\n" "$*"; }
info() { printf "${C_CYN}i${C_RST} %b\n" "$*"; }
hdr()  { printf "\n${C_BLD}%s${C_RST}\n" "$*"; printf '%.0s─' {1..60}; echo; }

detect_tailscale_ip() {
  if ! command -v tailscale >/dev/null 2>&1; then
    return 1
  fi
  tailscale ip -4 2>/dev/null | head -n1
}

detect_lan_ip() {
  # Tailscale 없으면 LAN IP 후보 (WSL eth0 등)
  ip -4 -o addr show 2>/dev/null \
    | awk '!/ lo / && !/ docker/ && !/ br-/ && !/ veth/ {print $4}' \
    | cut -d/ -f1 | grep -v '^127\.' | head -n1
}

check_token() {
  if [ ! -f "${TOKEN_FILE}" ]; then
    warn "토큰 파일이 아직 없습니다 (inter-session 한 번도 실행 안 됨)"
    info "해결: 평소처럼 '/inter-session connect <name>' 한 번 실행하면 자동 생성됩니다."
    return 1
  fi
  local perm
  # macOS는 'stat -f %A' (8진수만 출력), Linux는 'stat -c %a'.
  # 양쪽 모두 "0600" 또는 "600" 가능성 있어 leading-zero 제거 후 비교.
  perm=$(stat -c '%a' "${TOKEN_FILE}" 2>/dev/null || stat -f '%A' "${TOKEN_FILE}" 2>/dev/null)
  perm="${perm##0}"
  if [ "${perm}" != "600" ]; then
    warn "토큰 파일 권한이 ${perm} (600이어야 함). 즉시 수정합니다."
    chmod 600 "${TOKEN_FILE}" && ok "권한 600으로 재설정 완료"
  else
    ok "토큰 권한 OK (600)"
  fi
  ok "토큰 위치: ${TOKEN_FILE}"
}

print_host_mode() {
  local TS_IP="$1"
  hdr "🛰  HOST 모드 — 이 머신이 inter-session 서버"

  ok "감지된 Tailscale IPv4: ${C_BLD}${TS_IP}${C_RST}"
  echo
  info "이 머신에서 실행할 명령 (claude code 세션 시작 시):"
  echo
  printf "  ${C_BLD}export INTER_SESSION_HOST=${TS_IP}${C_RST}\n"
  printf "  ${C_BLD}/inter-session connect <이-머신-이름>${C_RST}\n"
  echo
  info "이후 server는 ${TS_IP}:${DEFAULT_PORT}에 listen (외부에서 reachable)"
  echo

  hdr "🔑 피어(다른 머신)에 토큰 전달"

  if command -v tailscale >/dev/null 2>&1; then
    info "Tailscale 파일 전송 사용 가능:"
    echo
    printf "  ${C_BLD}tailscale file cp ${TOKEN_FILE} <peer-hostname>:${C_RST}\n"
    echo
    info "또는 수동 복사 (피어 머신에서):"
    echo
    printf "  ${C_BLD}scp <this-host>:${TOKEN_FILE} ~/.claude/data/inter-session/token${C_RST}\n"
    printf "  ${C_BLD}chmod 600 ~/.claude/data/inter-session/token${C_RST}\n"
  else
    warn "Tailscale CLI 없음 — 수동 복사 필요"
  fi
  echo

  hdr "👥 피어 머신(예: Mac)에서 실행할 명령"
  echo
  printf "  ${C_BLD}export INTER_SESSION_HOST=${TS_IP}${C_RST}\n"
  printf "  ${C_BLD}/inter-session connect <피어-이름>${C_RST}\n"
  echo
  info "피어는 자체 server를 spawn하지 않고 ${TS_IP}:${DEFAULT_PORT}에 그냥 connect"
  warn "전제: 이 머신의 inter-session server가 먼저 떠 있어야 함"
}

print_client_mode() {
  hdr "👤 CLIENT 모드 — 피어 머신(서버)에 연결"
  echo
  info "필요 정보 (서버 머신에서 'inter-session-setup.sh' 실행하면 출력됨):"
  echo "  1. 서버 머신의 Tailscale IP"
  echo "  2. 서버 머신의 토큰 (복사받아 이 머신에도 동일하게 저장)"
  echo
  hdr "이 머신에서 실행할 명령"
  echo
  printf "  ${C_BLD}export INTER_SESSION_HOST=<서버-tailscale-ip>${C_RST}\n"
  printf "  ${C_BLD}/inter-session connect <이-머신-이름>${C_RST}\n"
  echo
  info "토큰이 일치하지 않으면 'unauthorized: bad token'으로 연결 거부됩니다."
}

# ─── main ──────────────────────────────────────────
MODE="${1:-host}"

hdr "🔍 inter-session Tailscale wizard"
info "data_dir: ${DATA_DIR}"
echo

check_token

case "${MODE}" in
  host)
    TS_IP=$(detect_tailscale_ip || true)
    if [ -z "${TS_IP}" ]; then
      warn "Tailscale IP를 감지하지 못했습니다."
      LAN_IP=$(detect_lan_ip || true)
      if [ -n "${LAN_IP}" ]; then
        info "Tailscale 미설치 환경입니다. LAN IP로 폴백: ${LAN_IP}"
        info "Tailscale 설치 권장: brew install tailscale  (macOS)  /  winget install tailscale.tailscale  (Windows)"
        TS_IP="${LAN_IP}"
      else
        err "사용 가능한 외부 IP가 없습니다. 인터페이스 확인: ip -4 addr"
        exit 1
      fi
    fi
    print_host_mode "${TS_IP}"
    ;;
  client|peer)
    print_client_mode
    ;;
  *)
    err "사용법: $0 [host|client]"
    exit 2
    ;;
esac

echo
hdr "📋 빠른 점검"
ok "코드 패치 불필요 — inter-session은 env 변수만으로 외부 노출 지원"
ok "기본값(INTER_SESSION_HOST 미설정)은 그대로 127.0.0.1 — opt-in 외부 노출"
ok "보안: 토큰 인증(server.py:225) + Tailscale WireGuard E2E + 파일 권한 600"
echo
