# NCO 시스템 메트릭을 조회합니다. 태스크 통계, 에이전트 수, 메모리 사용량 등을 표시합니다.

curl -s http://localhost:6200/api/observability/metrics | python3 -m json.tool
