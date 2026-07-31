---
description: codex·agy 필수 협업 강제 + 의견 상충 시 discussion→consensus 합의 도출
argument-hint: <작업 또는 상충 주제>
---

# /nco-collab-force — 필수 협업 강제 + 합의 오케스트레이션

아래 주제를 **codex와 agy를 필수 참여자로** 협업 처리하고, 두 산출물이 상충하면 토론→합의로 최상의 결론을 도출한다.

## 주제
$ARGUMENTS

## 절차 (순서대로)

### 1단계 — 병렬 위임 (codex + agy 필수)
```
Skill(nco-parallel) providers=[codex, agy] "구현/분석: $ARGUMENTS"
```
- codex 또는 agy가 리밋/오프라인이면: 대체 워커(hermes→ollama→opencode)로 우회하고 `[미참여: <에이전트>=<사유>]`를 명시(reroute 규칙). 강제로 실패 종료하지 말 것.
- 결과는 그대로 전달하지 말고 반드시 검토(cursor-agent 리뷰 권장).

### 2단계 — 상충 판정
codex 산출물과 agy 산출물을 비교한다:
- **일치/보완** → 통합안 작성 후 3단계 생략하고 4단계로.
- **상충(접근·결론이 다름)** → 3단계 합의 절차 진입.

### 3단계 — 합의 (상충 시에만)
```
Skill(nco-discussion) "토론: codex안 vs agy안 — <핵심 쟁점>. 근거와 트레이드오프 제시"
Skill(nco-consensus) "합의: 위 토론 기반 최적안 투표 (참여: codex, agy, opencode)"
```
- 토론에서 각 안의 근거·리스크를 드러내고, consensus 투표로 최적안을 선택.
- 동점이면 opencode(설계 관점)를 타이브레이커로.

### 4단계 — 게이트 + 결론
- 합의안을 Claude가 검토(맹목 수용 금지) 후 채택.
- 채택 근거와 각 에이전트 기여를 요약.
- 실제 구현/적용이 필요하면 검증(ollama)까지 수행.

## 규칙
- `$ARGUMENTS`가 비면: `사용법: /nco-collab-force <작업 또는 상충 주제>` 출력 후 종료.
- 모든 완료 주장에 CLAUDE.md 검증 영수증(T1) 첨부.
- codex·agy 강제는 **가용 시 필수**, 리밋/오프라인 시 **대체+플래그**(교착 금지).
- 관련: [[feedback_limit_reroute]] [[feedback_check_provider_limits]] [[feedback_nco_parallel_workflow]]
