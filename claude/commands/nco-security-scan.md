# AI/LLM 라이브러리 보안 취약점을 스캔하고 지식 베이스를 업데이트합니다.

# 사용법:
#   /nco-security-scan          — 즉시 스캔 실행
#   /nco-security-scan list     — 알려진 취약점 목록 조회
#   /nco-security-scan news     — 웹에서 최신 보안 뉴스 검색 (AI에게 위임)

KB="/home/nova/projects/security-kb/vulnerabilities.md"
ACTION="${ARGUMENTS:-scan}"

case "$ACTION" in
  list)
    echo "━━━ AI/LLM 보안 취약점 지식 베이스 ━━━"
    cat "$KB"
    ;;
  news)
    echo "최신 보안 뉴스는 AI가 웹 검색으로 조회합니다."
    echo "다음 라이브러리를 검색하세요: litellm, vllm, langchain, transformers, anthropic, openai"
    echo ""
    echo "현재 KB 경로: $KB"
    ;;
  scan|*)
    echo "━━━ 보안 스캔 시작 ━━━"
    bash /home/nova/projects/security-kb/daily-scan.sh
    echo ""
    echo "━━━ 최근 등록 취약점 (최신 5건) ━━━"
    grep "^##\|^| 20" "$KB" | tail -10
    ;;
esac
