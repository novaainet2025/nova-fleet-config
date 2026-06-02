# NCO 실시간 대시보드 v2.0 — 에이전트 상태, 큐, 활성 태스크, 이벤트, 명령어 워크플로우 통합 표시
# $ARGUMENTS를 옵션으로 사용합니다.
# 형식:
#   /nco-progress          # 2초 갱신 실시간 모니터 (Ctrl+C 종료)
#   /nco-progress once     # 현재 상태 한 번 출력
#   /nco-progress cmd      # 명령어 워크플로우만 표시
#   /nco-progress 5        # 5초 간격으로 갱신

# ```bash
ARG="${ARGUMENTS:-}"

if [ "$ARG" = "once" ]; then
  python3 ~/projects/nco-progress.py --once

elif [ "$ARG" = "cmd" ]; then
  python3 ~/projects/nco-progress.py --once --cmd

elif echo "$ARG" | grep -qE '^[0-9]+$'; then
  python3 ~/projects/nco-progress.py --interval "$ARG"

else
  python3 ~/projects/nco-progress.py --once
fi
```
