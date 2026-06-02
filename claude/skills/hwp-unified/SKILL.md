---
name: hwp-unified
description: >
  HWP/HWPX 작업을 단일 MCP(hwp-unified)로 실행하는 드라이버. 파일 유형(.hwp/.hwpx/.md)을
  자동 감지해 가장 적합한 엔진(pyhwp·python-hwpx·hwp_toolkit·rhwp·HwpForge)으로 라우팅한다.
  "한글/hwp/hwpx 추출·검증·렌더·편집·치환·변환·md변환"을 한 곳에서 처리할 때 사용.
  도구 선택 근거가 궁금하면 [[hwp-toolkit-guide]] 참조.
---

# hwp-unified — 통합 HWP 실행 드라이버

이 PC의 모든 한글 라이브러리를 **단일 MCP `hwp-unified`** 로 묶어, 파일 유형에 따라
최적 엔진을 자동 선택해 실행한다. (선택 *규칙* 설명은 `hwp-toolkit-guide`,
이 스킬은 *실행* 드라이버 — 역할 분리)

## 🔌 MCP 도구 (mcp__hwp-unified__*)

| 도구 | 하는 일 | 자동 라우팅 |
|---|---|---|
| `hwp_inventory` | 설치된 엔진 + 가용성 라이브 체크 | — |
| `hwp_detect(path)` | 형식 감지(hwp5/hwpx/md) + 권장 엔진 | magic bytes |
| `hwp_extract_text(path)` | UTF-8 본문 추출 | HWPX→python-hwpx, HWP5→pyhwp(hwp5txt) |
| `hwp_validate(path)` | 무결성 검증 | HWPX→validate_hwpx, HWP5→olefile |
| `hwp_render(path,fmt,page)` | SVG/PNG 렌더(시각 검증) | rhwp |
| `hwp_replace_text(path,find,replace,out)` | 찾기/바꾸기 | HWPX→hwp_toolkit(안전), HWP5→변환 라우팅 안내 |
| `hwp_convert(path,out)` | 변환 (출력 확장자로 타깃 결정) | 네이티브: HWPX→MD(Doc.markdown)·HWP5→MD(rhwp, 페이지별 디렉터리)·HWP5배포본→편집HWP(rhwp convert). HwpForge필요(→.hwpx 등)는 `hwpforge` MCP로 라우팅 |
| `hwp_md_to_hwpx(md,out,template?)` | MD→HWPX | HwpForge CLI(미빌드시) → `template=<style.hwpx>` 주면 apply_md_to_hwpx.py, 아니면 `hwpforge` MCP 안내 |
| `hwp_route(task)` | 자연어 작업 → 최적 도구 추천 | 가이드 규칙 |

## ✅ 사용 흐름

1. **형식 모르면** `hwp_detect(path)` 먼저 → 권장 엔진 확인.
2. **추출/검증/렌더**는 read-only이므로 바로 호출.
3. **편집**:
   - `.hwpx` → `hwp_replace_text`(순수 Python, 손상 버그 없음). **편집 후 `hwp_extract_text`로 T1 재검증**.
   - `.hwp`(HWP5 바이너리) → 안전한 pure-Python 편집기 없음. `hwp_convert(.hwp→.hwpx)` 후 편집, 또는 Windows `hwp`(jkf87 COM) MCP 사용(세션당 저장 1회+크기검증 철칙).
4. **MD↔HWPX** → `hwp_convert` / `hwp_md_to_hwpx`.

## ⚠️ 철칙
- **편집 후 항상 재추출로 T1 검증**, 원본은 백업.
- 특수문자 경로(`@@`·한글·공백)는 서버가 `/tmp`로 자동 복사해 처리하지만,
  `/mnt/d` 한글 파일명은 비UTF-8 로케일에서 셸 glob이 깨짐 → `LC_ALL=C.UTF-8` 또는 `os.listdir` 사용.
- 정밀 한글 서식(자간/줄간격/COM)은 Windows `hwp` MCP 영역 — 이 드라이버는 라우팅 안내만.

## 관련
- 도구 선택 규칙·장단점: `hwp-toolkit-guide`
- 기반 라이브러리: `hwp_toolkit`(`~/projects/hwp_toolkit`), python-hwpx, rhwp, HwpForge
- 서버 소스: `~/projects/hwp_toolkit/mcp_server.py`
