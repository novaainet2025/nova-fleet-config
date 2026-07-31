# AI/LLM 라이브러리 보안 취약점을 스캔하고 지식 베이스를 업데이트합니다.

# 사용법:
#   /nco-security-scan          — 즉시 스캔 실행
#   /nco-security-scan list     — 알려진 취약점 목록 조회
#   /nco-security-scan news     — 웹에서 최신 보안 뉴스 검색 (AI에게 위임)

KB_ROOT="${NCO_SECURITY_KB_DIR:-$HOME/projects/security-kb}"
KB="$KB_ROOT/vulnerabilities.md"
SCAN_SCRIPT="$KB_ROOT/daily-scan.sh"
ACTION="${ARGUMENTS:-scan}"

case "$ACTION" in
  list)
    echo "━━━ AI/LLM 보안 취약점 지식 베이스 ━━━"
    if [ -f "$KB" ]; then
      cat "$KB"
    else
      echo "로컬 보안 KB가 없습니다: $KB"
      echo "NCO_SECURITY_KB_DIR로 위치를 지정하거나 현재 프로젝트에서 /nco-security-scan을 실행하세요."
    fi
    ;;
  news)
    echo "최신 보안 뉴스는 AI가 웹 검색으로 조회합니다."
    echo "다음 라이브러리를 검색하세요: litellm, vllm, langchain, transformers, anthropic, openai"
    echo ""
    echo "현재 KB 경로: $KB"
    ;;
  scan|*)
    echo "━━━ 보안 스캔 시작 ━━━"
    if [ -f "$SCAN_SCRIPT" ]; then
      bash "$SCAN_SCRIPT"
      echo ""
      echo "━━━ 최근 등록 취약점 (최신 5건) ━━━"
      grep "^##\|^| 20" "$KB" | tail -10
    elif [ -f package.json ]; then
      echo "전용 KB 스캐너가 없어 현재 Node 프로젝트를 npm audit으로 검사합니다."
      npm audit --omit=dev --audit-level=high || true
    else
      echo "검사 가능한 security-kb 또는 package.json을 찾지 못했습니다."
    fi
    ;;
esac
