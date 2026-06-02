---
name: hwp-edit-workflow
description: >
  한글(.hwp/.hwpx) 문서를 여러 라이브러리의 강점만 조합해 "완벽하게" 수정하는 실행
  워크플로우. 표·이미지·서식을 보존한 채 텍스트 전면 재작성, 임베드 이미지 교체,
  다중 문서 일괄 편집을 한다. "한글/hwp 문서 수정·편집·치환·이미지 교체·서식보존·
  전면 개조·내용 바꾸기"를 요청하면 사용. 도구 표면은 mcp__hwp-unified__*.
  형식 자동감지·추출·렌더·변환은 [[hwp-unified]], 선택 근거는 [[hwp-toolkit-guide]].
---

# hwp-edit-workflow — 멀티 라이브러리 한글 편집 드라이버

각 라이브러리의 **강점만** 살려 .hwp/.hwpx를 서식·표·이미지 보존하며 수정한다.
실행은 전부 `hwp-unified` MCP 툴(`mcp__hwp-unified__*`). (2026-06-02 E2E 검증)

## ⚡ 강점 기반 도구 분담 (핵심 규칙)

| 작업 | 최적 도구(강점) | MCP 툴 |
|---|---|---|
| 텍스트 추출(정확) | pyhwp(hwp5txt) | `hwp_extract_text` |
| 잔여용어 카운트·표 확인 | unhwp | (검증 시) |
| **임베드 이미지 추출** | hwp-extract(Volexity) | `hwp_extract_images` |
| **페이지 렌더(시각/서식검증)** | rhwp | `hwp_render` |
| 문단 구조 덤프 | hwplib | `hwp_dump_paragraphs` |
| **.hwp 다수 문단 텍스트 편집** | **COM(한글 네이티브)** | `hwp_edit_text` (route=com) |
| .hwpx 텍스트 편집 | python-hwpx/hwp_toolkit | `hwp_edit_text` (auto) |
| **.hwp 임베드 이미지 교체** | **hwplib(BinData)** | `hwp_replace_images` |
| .hwp/.hwpx→Markdown(표) | unhwp | `hwp_to_markdown` |
| 새 HWPX 생성(프리셋·표·이미지) | pyhwpxlib | `hwp_build_hwpx` |
| 이미지 생성 | Higgsfield | `/higgsfield` |
| 이미지 치수/형식 맞춤(슬롯) | Pillow | `hwp_fit_image` |
| 편집 검증 | olefile+hwp-extract+unhwp | `hwp_verify_edit` |
| 설치/가용 라이브러리 점검 | (전체) | `hwp_inventory` |

> **왜 분담하나** (실측): hwplib는 .hwp를 COM 없이 Linux에서 read/write하지만,
> **다수 문단을 clear+addString하면 인라인 제어문자가 깨져 한글이 거부**한다.
> 그래서 **텍스트 다수 재작성은 COM(win32com AllReplace, 서식·제어문자 보존)**,
> **이미지 교체는 hwplib(COM엔 이미지 삽입도구 없음)** 로 나눈다.

## 📋 표준 워크플로우 (전면 개조 예)

```
① 이해   hwp_extract_text + hwp_extract_images + hwp_render + hwp_dump_paragraphs
② 계획   덤프(SxPy)로 문단별/용어별 치환 맵 작성 (longest-first), 이미지 슬롯 파악
③ 편집-텍스트  hwp_edit_text(path,out,pairs)  # .hwp→COM 자동라우팅
④ 편집-이미지  /higgsfield 생성 → Pillow로 슬롯 원본 치수·형식 맞춤 → hwp_replace_images
⑤ 검증   hwp_verify_edit(absent_terms,present_terms,expect_images) + hwp_render 비교
         + 한글 재열기(지상진실, jkf87 `hwp` MCP hwp_open+find_text)
```

빠른 안내: `hwp_workflow` 툴이 위 규칙을 런타임에 반환한다.

## ✅ 사용 규칙

1. **원본 보존**: 항상 복사본을 `out`으로 만든다(원본 미접촉).
2. **치환 순서**: 용어 맵은 **긴 문자열 먼저**(전광판 계열 등 부분매칭 방지).
3. **전체 문단 재작성**: `find`에 원문 문단 전체를 넣어 `hwp_edit_text`로 교체(자연스러운 문장).
4. **이미지**: 새 이미지는 슬롯 원본과 **같은 형식**(PNG↔PNG, BMP↔BMP) + 같은 픽셀치수로 맞춘다(프레임 왜곡 방지). 교체 검증은 md5.
5. **검증 등급**: 텍스트는 **unhwp**로 읽는다(hwplib 출력은 pyhwp가 못 읽음). 최종은 **한글 재열기**.
6. **.hwp→진짜 hwpx(이미지 보존) 변환은 현재 OSS 부재** — HwpForge 빌드 또는 한글 SaveAs 필요.

## 🚫 안 되는 것 / 함정
- hwplib로 다수 문단 텍스트 재작성 → 한글 열기 거부(제어문자 파괴). 텍스트는 COM로.
- jkf87 COM은 표 셀 일부·책갈피 삽입이 환경따라 막힘(InsertFieldBookmark Execute=False 관측).
- COM 저장은 세션당 1회 + 크기검증 철칙([[project_hwp_save_gotcha]]).

## 의존
- JDK17(`java`) + `java_bridge/lib/hwplib-1.1.9.jar` (hwplib)
- `.venv-hwp`(unhwp·hwp-extract·olefile·Pillow), `~/.local/bin`(hwp5txt·rhwp)
- Windows python+win32com(COM 편집), Higgsfield CLI(이미지)

관련 메모리: [[project_hwplib_linux_hwp_edit]] · [[project_hwp_save_gotcha]] · [[project_hwp_unified_mcp]]
