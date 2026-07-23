# AGENTS.md — codex/agy/opencode 공통 코어룰 (자동생성: provider-rules/CORE-RULES.md 파생)

> 모든 코딩 에이전트(claude/codex/agy/opencode/cursor/ollama)에 동일 적용되는 최소 핵심 규칙.
> 이 파일이 SSOT. `.cursorrules`·`AGENTS.md`는 여기서 파생 배포한다.

## 1. 거짓·미검증 보고 금지 (최우선)
"검증되지 않은 성공은 실패보다 나쁘다." grep 문자열 존재 ≠ 동작 · 메시지 전달 ≠ 완료 · 일부 통과 ≠ 100% · 자기 보고 ≠ 검증.
- **완료/PASS/성공/done/fixed** 주장은 같은 작업 내 실제 검증 도구(shell/read/curl) 호출 후에만.
- **Pre-claim verify**: "X 했다"고 말하기 전에 X의 부작용을 직접 확인하는 명령을 먼저 실행.

## 2. 증거 등급 (Evidence Tier) — 모든 검증에 명시
- **T1** 지상 진실: 파일시스템(`ls`/`cat`/`stat`), DB row, HTTP 응답 본문, git hash
- **T2** 간접: 프로세스(`ps`), 포트(`lsof`), 파일 존재만
- **T3** 상태 문자열: API ack, exit 0, 도구 성공 메시지
- **T4** LLM 자연어: 다른 에이전트 보고
→ "완료" 주장엔 **T1 필수**. T3·T4만이면 "전송됨"까지만 허용.

## 3. 검증 영수증 (보고 필수 포맷)
```
## 검증 영수증
- [변경] path/file:line — what
- [검증방법] <실제 명령 + 출력 발췌>
- [등급] T1|T2|T3
- [Gap] N% (실제 완료율)
- [미검증항목] (있으면 명시, 없으면 '없음')
```

## 4. 결과 검증은 verify.sh로
작업 완료 후 반드시 실행하고 exit 코드·영수증을 확인:
```
verify.sh --file <산출물> --grep '<기대문자열>::<파일>' --http <URL> --cmd '<테스트>'
```
exit 0 = 완료 가능 · exit 1 = 미달 → 재작업 루프.

## 5. 루프: Plan → Act → Verify → Gap → (미달 시)Rework
목표를 체크리스트로 분해 → 수행 → verify.sh T1 수집 → Gap 계산 → 전부 통과 전까지 재작업(최대 5회). 완료 판정은 자기보고가 아니라 verify.sh exit 0.
