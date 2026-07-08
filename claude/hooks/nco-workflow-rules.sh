#!/bin/bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작 (2026-07-08, 76s 훅스택+BOOTSTRAP 오염 T1)
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
# NCO 워크플로우 규칙 — task_type별 필수 단계 정의 (단일 진실 소스)
#
# Sourced 전용 (실행권한 불필요). 사용:
#   source {{HOME}}/.claude/hooks/nco-workflow-rules.sh
#   required_stages_for "$TASK_TYPE"
#   missed_required_stages "$STAGE_FILE" "$TASK_TYPE"
#
# 우회: NCO_WORKFLOW_BYPASS=1 환경변수가 1이면 모든 함수가 빈 결과를 반환.
#
# stage 이름은 nco-track-agent-use.sh:148-183의 매핑과 일치해야 함:
#   discussion / design / implementation / review / gap_analysis / verification

# ── 정책 테이블 (CLAUDE.md "작업 유형별 최소 필수 단계" 미러) ──
# 변경 시 docs/nco-workflow-policy.md 와 CLAUDE.md 도 함께 갱신할 것.
required_stages_for() {
    [ "${NCO_WORKFLOW_BYPASS:-0}" = "1" ] && { echo ""; return 0; }

    case "${1:-unknown}" in
        bug)         echo "implementation verification" ;;
        new_feature) echo "discussion implementation review gap_analysis verification" ;;
        config)      echo "implementation gap_analysis" ;;
        # R1-F (2026-05-27): mesh peer로 위임받은 task는 짧은 작업 단위 —
        # 토론·합의는 발송 측이 이미 결정. 수신 측은 구현+검증만 필요.
        mesh_delegated)
                     echo "implementation verification" ;;
        simple|query|unknown|"")
                     echo "" ;;
        *)           echo "" ;;
    esac
}

# stages.json에서 false 상태인 필수 단계만 공백 구분으로 출력.
# stages.json이 없거나 파싱 불가면 모든 필수 단계를 누락으로 간주.
missed_required_stages() {
    local stages_file="$1"
    local task_type="$2"
    [ "${NCO_WORKFLOW_BYPASS:-0}" = "1" ] && { echo ""; return 0; }

    local required
    required=$(required_stages_for "$task_type")
    [ -z "$required" ] && { echo ""; return 0; }

    python3 - "$stages_file" "$required" <<'PYEOF' 2>/dev/null
import json, os, sys

stages_file = sys.argv[1]
required = sys.argv[2].split()

stages = {}
if os.path.exists(stages_file):
    try:
        stages = json.load(open(stages_file))
    except Exception:
        stages = {}

missed = [s for s in required if not stages.get(s, False)]
print(" ".join(missed))
PYEOF
}

# task_type → 추천 NCO 명령 매핑 (stderr 메시지용)
nco_command_for_stage() {
    case "${1:-}" in
        discussion)     echo "Skill(nco-discussion) 또는 Skill(nco-task) opencode '설계: ...'" ;;
        design)         echo "Skill(nco-task) opencode '아키텍처 설계: ...'" ;;
        implementation) echo "Skill(nco-task) codex '구현: ...'" ;;
        review)         echo "Skill(nco-task) cursor-agent '코드 리뷰: ...'" ;;
        gap_analysis)   echo "Skill(nco-gap) 또는 Skill(nco-task) ollama 'Gap 분석: ...'" ;;
        verification)   echo "Skill(nco-task) ollama '검증: ...'" ;;
        *)              echo "Skill(nco-task) <agent> '...'" ;;
    esac
}
