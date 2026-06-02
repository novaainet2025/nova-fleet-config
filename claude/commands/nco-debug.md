# Ollama 프록시 디버그 메뉴 — 전체 서브커맨드 인덱스 및 직접 실행.

# 사용법: /nco-debug [status|errors|recover|test|clear|help]
# 각 서브커맨드는 독립 슬래시 명령으로도 사용 가능합니다.

PROXY_URL="http://localhost:${PROXY_PORT:-4100}"
cmd="${1:-help}"

_header() { echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; echo "  $1"; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

case "$cmd" in
  status)
    exec bash "$(dirname "$0")/nco-debug-status.md" ;;

  errors)
    exec bash "$(dirname "$0")/nco-debug-errors.md" ;;

  recover)
    exec bash "$(dirname "$0")/nco-debug-recover.md" "${2:-auto}" ;;

  recover:model_refresh|model_refresh)
    exec bash "$(dirname "$0")/nco-debug-recover-model.md" ;;

  recover:ctx_refresh|ctx_refresh)
    exec bash "$(dirname "$0")/nco-debug-recover-ctx.md" ;;

  recover:error_clear|clear)
    exec bash "$(dirname "$0")/nco-debug-clear.md" ;;

  test)
    exec bash "$(dirname "$0")/nco-debug-test.md" ;;

  help|*)
    _header "nco-debug — Ollama 프록시 디버그 도구"
    echo ""
    echo "  슬래시 명령 (/ 메뉴에서 직접 선택 가능):"
    echo ""
    echo "  /nco-debug-status              헬스 + 에러 통계"
    echo "  /nco-debug-errors              최근 에러 목록 (타입별 분류)"
    echo "  /nco-debug-recover             자가 복구 실행 (auto: 3단계 일괄)"
    echo "  /nco-debug-recover-model       모델 캐시 강제 갱신"
    echo "  /nco-debug-recover-ctx         컨텍스트 한계 재감지"
    echo "  /nco-debug-test                end-to-end 추론 테스트"
    echo "  /nco-debug-clear               에러 카운터 초기화"
    echo ""
    echo "  통합 명령 (이 파일):"
    echo "  /nco-debug status              위와 동일"
    echo "  /nco-debug errors"
    echo "  /nco-debug recover [액션]      액션: auto|model_refresh|health_check|ctx_refresh|error_clear"
    echo "  /nco-debug test"
    echo "  /nco-debug clear"
    echo ""
    echo "  프록시 HTTP 엔드포인트:"
    echo "  GET  ${PROXY_URL}/debug/status"
    echo "  POST ${PROXY_URL}/debug/recover  — body: {\"action\":\"auto\"}"
    echo ""
    echo "  MCP 도구 (Claude가 직접 호출):"
    echo "  nco_proxy_debug({ action: \"status|errors|test|recover|recover:model_refresh|...\" })"
    ;;
esac
