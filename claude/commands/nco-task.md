# 단일 AI에 작업을 위임합니다.
# $ARGUMENTS를 파싱하여 NCO 서버에 작업을 전달합니다.
# 형식: /nco-task <AI이름> <작업내용>
# 예: /nco-task codex auth 모듈에 JWT 검증 추가

nco-task $ARGUMENTS
