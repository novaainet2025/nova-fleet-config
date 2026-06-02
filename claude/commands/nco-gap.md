현재 작업의 Gap 분석을 수동으로 실행합니다.

1. docs/plans/*.md 또는 .llm/todo.md에서 전체 태스크 목록을 파싱한다.
2. 완료(- [x]) vs 미완료(- [ ]) 비율을 계산한다.
3. TypeScript 에러(tsc --noEmit)를 확인한다.
4. 변경된 파일의 ESLint 에러를 확인한다.
5. 종합 Gap Rate를 계산하여 보고한다.

보고 형식:
  Gap Rate: XX%
  태스크: N/M 완료
  tsc 에러: N개
  lint 에러: N개
  미완료 항목 목록
  추천 다음 작업

$ARGUMENTS 가 있으면 특정 Plan 파일을 대상으로 분석한다.
