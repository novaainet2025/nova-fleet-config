---
name: hwp-toolkit-guide
description: >
  HWP(한글) 문서 작업 시 어떤 라이브러리/MCP를 써야 하는지 선택 가이드.
  HWP/HWPX 파일을 읽기·추출·렌더링·편집·변환·검증할 때, 또는 "한글 문서/hwp/hwpx
  처리/편집/변환/렌더" 요청 시 사용. 각 도구의 장단점과 상황별 선택, 저장 손상 회피법 포함.
---

# HWP(한글) 툴킷 선택 가이드

이 PC에 설치된 한글 라이브러리/MCP 인벤토리와, **상황별 최적 도구 선택** 규칙.
(2026-05-30 전수 조사 기준)

## 🧰 설치된 도구 인벤토리

| 도구 | 종류 | 위치 | 능력 | 형식 |
|---|---|---|---|---|
| **pyhwp / hwp5** 0.1b15 | Python(WSL) | `~/.local/bin/hwp5txt,html,proc,odt` | 텍스트/HTML/ODT 추출 (**읽기전용**) | HWP5 |
| **olefile** 0.47 | Python(WSL) | WSL 글로벌 | OLE 컨테이너 검증·스트림 읽기 | HWP5 |
| **rhwp** 0.7.12 | Rust CLI | `~/.local/bin/rhwp` (src `~/projects/rhwp`, edwardkim/rhwp) | info/dump/diag, export-svg/**png(VLM)**/text/markdown, thumbnail, **convert**(배포본→편집가능), ir-diff(HWPX↔HWP) | HWP5 (읽기+렌더), 편집은 WASM |
| **python-hwpx** 2.9.1 | Python venv | `~/projects/.venv-hwp` | **HWPX 읽기+쓰기**, OWPML 70+ 메서드, find/replace, CLI: hwpx-pack/unpack/text-extract/validate/page-guard | HWPX |
| **hwp_toolkit** | Python(커스텀) | `~/projects/hwp_toolkit` | python-hwpx 래퍼 + find_text/replace_text·apply_style·outline + 브리지(hwpforge/jkf87/rhwp) | HWPX |
| **HwpForge** 0.5.2 | Rust CLI/MCP | `C:\Users\lovecat\HwpForge` | HWP5/HWPX/MD 헤드리스 코덱, restyle/patch/to_json | HWP5·HWPX·MD |
| **한글 Office 2022** | 프로그램(Win) | `C:\Program Files (x86)\Hnc\Office 2022` | COM 자동화 대상(실제 한글) | HWP·HWPX |
| pywin32 311 / comtypes 1.4.16 | Python(Win) | Win Py3.12 | 한글 COM 제어 | — |

## 🔌 MCP 서버 (2개)
- **`hwp`** (jkf87, Windows COM): 한글을 직접 제어 → 열기/치환/표/저장. **쓰기 가능하나 반복 SaveAs 시 12KB 손상·파일 부풀림(29MB)·크래시 버그 있음** ([[project_hwp_save_gotcha]]).
- **`hwpforge`** (@hwpforge/mcp 0.5.2): Rust 헤드리스 코덱. convert/inspect/patch/restyle/to_json/from_json/to_md/validate/templates.

## ✅ 상황별 선택 규칙

**1) 읽기 / 텍스트 추출 / 검증 (HWP5 .hwp)**
→ `hwp5txt`(정확한 UTF-8 본문, find 문자열 확보용), `rhwp info/dump/diag`. olefile로 OLE 무결성.
※ 한글 MCP의 `hwp_get_text`는 인코딩 깨짐 → 쓰지 말고 hwp5txt 사용.

**2) 시각 검증 / 렌더 (실제 페이지를 눈으로 확인)**
→ `rhwp export-svg`(항상) 또는 `export-png --vlm-target claude`(native-skia 빌드 필요). 표 셀은 `hwp5html`로 추출(hwp5txt는 `<표>`로 생략).

**3) 편집 — HWPX (.hwpx) ★권장 경로**
→ **python-hwpx / hwp_toolkit** (순수 Python, 한글·COM 불필요, **손상 버그 없음**, 줄바꿈·표 정상). find_text/replace_text/apply_style.
→ 또는 hwpforge MCP patch/restyle.

**4) 편집 — HWP5 바이너리 (.hwp)**
→ 순수 편집 라이브러리 없음. 선택지: (a) **`.hwpx`로 변환 후 python-hwpx 편집**(가장 안전, 권장), (b) jkf87 hwp MCP COM(저장 버그 주의 — 세션당 저장 1회+크기검증, [[project_hwp_save_gotcha]]), (c) HwpForge.
→ COM 사용 시 철칙: 백업→단일세션→`hwp_save`(no-path)→temp 크기>1MB 확인→cp.

**5) HWP↔HWPX 비교 / 변환**
→ `rhwp ir-diff A.hwpx B.hwp`(IR 불일치 검출), `hwpforge convert`, `rhwp convert`(배포본→편집가능).

**6) MD ↔ HWPX**
→ hwpforge to_md/from_json, `~/projects/scripts/apply_md_to_hwpx.py`, hwp_toolkit. (GS 워크플로우 [[project_hwp_workflow_gs]])

## ⚠️ 핵심 원칙
- **.hwp 편집은 가능하면 .hwpx로 변환 후 python-hwpx**로 (COM 손상 회피).
- **모든 편집 후 hwp5txt 재추출로 T1 검증**, 원본은 항상 백업.
- 특수문자 경로(`@@`·한글·공백)는 rhwp/일부 CLI가 못 읽음 → 단순경로(`/tmp/x.hwp`)로 복사 후 처리.
