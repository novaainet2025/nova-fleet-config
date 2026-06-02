# NCO PyPI 패키지 전문 검색 — Python 라이브러리 · 프레임워크 · 도구
# 형식: /nco-search-pypi <패키지명 또는 기능>
# 예: /nco-search-pypi sentence transformers
# 예: /nco-search-pypi llm inference framework
# 예: /nco-search-pypi "langchain" (정확한 패키지명)
# 예: /nco-search-pypi web scraping async
#
# 무료 API:
#   - PyPI JSON API: pypi.org/pypi/<name>/json (무료)
#   - PyPI Stats: pypistats.org/api (무료)
#   - PyPI 검색: pypi.org/search/?q= (HTML만 — curl 불가, WebSearch 사용)

---

## STEP 1: 검색 쿼리 파싱 + 모드 결정

아래 bash를 실행하여 $ARGUMENTS를 파싱하고 DIRECT 모드(단일 패키지명)인지 SEARCH 모드(다중 단어 쿼리)인지 판별한다.

```bash
#!/usr/bin/env bash
set -euo pipefail

QUERY="$ARGUMENTS"

# 따옴표 제거
QUERY="${QUERY//\"/}"
QUERY="${QUERY//\'/}"
QUERY="$(echo "$QUERY" | xargs)"  # trim whitespace

if [ -z "$QUERY" ]; then
  echo "[ERROR] 검색어가 없습니다. 사용법: /nco-search-pypi <패키지명 또는 검색어>"
  exit 1
fi

WORD_COUNT=$(echo "$QUERY" | wc -w)

# 단일 단어 + 하이픈/언더스코어 허용 = 패키지명으로 간주
if [ "$WORD_COUNT" -eq 1 ] && echo "$QUERY" | grep -qP '^[a-zA-Z0-9][a-zA-Z0-9._-]*$'; then
  MODE="DIRECT"
else
  MODE="SEARCH"
fi

echo "============================================"
echo "[PyPI 검색]"
echo "  쿼리: $QUERY"
echo "  모드: $MODE"
echo "============================================"

# 다음 단계에서 사용할 수 있도록 변수 출력
echo "PYPI_QUERY=$QUERY"
echo "PYPI_MODE=$MODE"

# DIRECT 모드: 단일 패키지 상세 조회
if [ "$MODE" = "DIRECT" ]; then

python3 - "$ARGUMENTS" << 'PYEOF'
import sys, json, urllib.request, urllib.error, datetime, os, re

raw_arg = " ".join(sys.argv[1:]).strip().strip("'\"")
pkg_name = raw_arg.lower().strip()

if not pkg_name:
    print("[ERROR] 패키지명이 비어 있습니다.")
    sys.exit(1)

print(f"\n{'='*60}")
print(f"  PyPI 패키지 상세 조회: {pkg_name}")
print(f"{'='*60}\n")

# ── 1. PyPI JSON API ──
pypi_url = f"https://pypi.org/pypi/{pkg_name}/json"
print(f"[1/2] PyPI API 호출: {pypi_url}")

try:
    req = urllib.request.Request(pypi_url, headers={"User-Agent": "nco-search-pypi/1.0"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.loads(resp.read().decode())
except urllib.error.HTTPError as e:
    if e.code == 404:
        print(f"\n[NOT FOUND] '{pkg_name}' 패키지가 PyPI에 없습니다.")
        print(f"  비슷한 이름을 검색하려면: /nco-search-pypi {pkg_name}")
        # 정규화 이름 시도 (언더스코어 <-> 하이픈)
        alt = pkg_name.replace("-", "_") if "-" in pkg_name else pkg_name.replace("_", "-")
        if alt != pkg_name:
            print(f"  혹시 '{alt}'을(를) 의미하셨나요?")
    else:
        print(f"[ERROR] PyPI API HTTP {e.code}: {e.reason}")
    sys.exit(1)
except Exception as e:
    print(f"[ERROR] PyPI API 요청 실패: {e}")
    sys.exit(1)

info = data.get("info", {})

name = info.get("name", pkg_name)
version = info.get("version", "?")
summary = info.get("summary", "(설명 없음)")
author = info.get("author") or info.get("maintainer") or "(알 수 없음)"
author_email = info.get("author_email") or ""
license_name = info.get("license") or "(명시 안 됨)"
requires_python = info.get("requires_python") or "(제한 없음)"
keywords = info.get("keywords") or ""
project_urls = info.get("project_urls") or {}
home_page = info.get("home_page") or project_urls.get("Homepage", "")
classifiers = info.get("classifiers") or []
requires_dist = info.get("requires_dist") or []

# 라이선스가 길면 첫 줄만
if license_name and len(license_name) > 80:
    license_name = license_name.split("\n")[0][:80] + "..."

# 릴리스 날짜 (최신 버전)
releases = data.get("releases", {})
release_date = "?"
if version in releases and releases[version]:
    try:
        upload_time = releases[version][-1].get("upload_time", "")
        if upload_time:
            release_date = upload_time[:10]
    except Exception:
        pass

# GitHub URL 추출
github_url = ""
for label, url in project_urls.items():
    if url and "github.com" in url.lower():
        github_url = url
        break
if not github_url and home_page and "github.com" in home_page.lower():
    github_url = home_page

# ── 2. pypistats.org ──
print(f"[2/2] 다운로드 통계 조회: pypistats.org")

dl_last_day = dl_last_week = dl_last_month = "?"
try:
    stats_url = f"https://pypistats.org/api/packages/{pkg_name}/recent"
    req2 = urllib.request.Request(stats_url, headers={"User-Agent": "nco-search-pypi/1.0"})
    with urllib.request.urlopen(req2, timeout=10) as resp2:
        stats = json.loads(resp2.read().decode())
    dl_data = stats.get("data", {})
    dl_last_day = f"{dl_data.get('last_day', 0):,}"
    dl_last_week = f"{dl_data.get('last_week', 0):,}"
    dl_last_month = f"{dl_data.get('last_month', 0):,}"
except Exception as e:
    print(f"  [WARN] pypistats 조회 실패: {e}")

# ── 보고서 생성 ──
report_lines = []
report_lines.append(f"# PyPI 패키지: {name}")
report_lines.append(f"")
report_lines.append(f"조회일: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M')} | API: pypi.org + pypistats.org")
report_lines.append(f"")
report_lines.append(f"## 기본 정보")
report_lines.append(f"")
report_lines.append(f"| 항목 | 값 |")
report_lines.append(f"|------|-----|")
report_lines.append(f"| **이름** | [{name}](https://pypi.org/project/{name}/) |")
report_lines.append(f"| **버전** | {version} (릴리스: {release_date}) |")
report_lines.append(f"| **설명** | {summary} |")
report_lines.append(f"| **작성자** | {author} |")
report_lines.append(f"| **라이선스** | {license_name} |")
report_lines.append(f"| **Python** | {requires_python} |")
if github_url:
    report_lines.append(f"| **GitHub** | {github_url} |")
if home_page and home_page != github_url:
    report_lines.append(f"| **홈페이지** | {home_page} |")
report_lines.append(f"")
report_lines.append(f"## 다운로드 통계")
report_lines.append(f"")
report_lines.append(f"| 기간 | 다운로드 수 |")
report_lines.append(f"|------|-----------|")
report_lines.append(f"| 최근 1일 | {dl_last_day} |")
report_lines.append(f"| 최근 1주 | {dl_last_week} |")
report_lines.append(f"| 최근 1개월 | {dl_last_month} |")
report_lines.append(f"")

if keywords:
    kw_list = [k.strip() for k in keywords.replace(",", " ").split() if k.strip()]
    if kw_list:
        report_lines.append(f"## 키워드")
        report_lines.append(f"")
        report_lines.append(" ".join(f"`{k}`" for k in kw_list[:20]))
        report_lines.append(f"")

if requires_dist:
    report_lines.append(f"## 주요 의존성")
    report_lines.append(f"")
    # 필수 의존성만 (extra 조건 없는 것)
    core_deps = [d.split(";")[0].strip().split(" ")[0].split("(")[0].split("[")[0].split("<")[0].split(">")[0].split("=")[0].split("!")[0].strip()
                 for d in requires_dist if "extra ==" not in d and "extra==" not in d]
    core_deps = list(dict.fromkeys(core_deps))  # 중복 제거, 순서 유지
    if core_deps:
        report_lines.append(", ".join(f"`{d}`" for d in core_deps[:30]))
    else:
        report_lines.append("(필수 의존성 없음 — 모두 optional)")
    report_lines.append(f"")

# 주요 분류자 (Topic, Framework, License 등)
if classifiers:
    topics = [c for c in classifiers if c.startswith("Topic")]
    frameworks = [c for c in classifiers if "Framework" in c]
    notable = topics[:5] + frameworks[:3]
    if notable:
        report_lines.append(f"## 분류")
        report_lines.append(f"")
        for c in notable:
            report_lines.append(f"- {c}")
        report_lines.append(f"")

# project_urls 전체
if project_urls:
    report_lines.append(f"## 프로젝트 링크")
    report_lines.append(f"")
    for label, url in project_urls.items():
        if url:
            report_lines.append(f"- **{label}**: {url}")
    report_lines.append(f"")

report_lines.append(f"## 설치")
report_lines.append(f"")
FENCE = chr(96)*3
report_lines.append(f"{FENCE}bash")
report_lines.append(f"pip install {name}")
report_lines.append(f"# 또는")
report_lines.append(f"uv add {name}")
report_lines.append(FENCE)
report_lines.append(f"")

report = "\n".join(report_lines)

# ── 콘솔 출력 ──
print(f"\n{report}")

# ── 파일 저장 ──
safe_name = re.sub(r'[^a-zA-Z0-9_-]', '_', name)
ts = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
out_dir = os.path.join(os.getcwd(), "docs", "search")
os.makedirs(out_dir, exist_ok=True)
out_path = os.path.join(out_dir, f"{ts}-pypi-{safe_name}.md")
with open(out_path, "w", encoding="utf-8") as f:
    f.write(report)
print(f"\n[SAVED] {out_path}")
PYEOF

fi  # end DIRECT mode
```

---

## STEP 2B: SEARCH 모드 — 다중 단어 쿼리

$ARGUMENTS가 다중 단어(SEARCH 모드)인 경우, PyPI에는 JSON 검색 API가 없으므로 **WebSearch 도구를 사용**하여 관련 패키지를 찾는다.

**Claude에게 지시**: 아래 단계를 따른다.

1. **WebSearch 도구로 검색** (2회):
   - `site:pypi.org $ARGUMENTS`
   - `python $ARGUMENTS best library 2025`

2. **검색 결과에서 패키지명 추출** — pypi.org/project/<name>/ 형태의 URL에서 패키지명을 파싱한다. 상위 5~8개를 선별한다.

3. **각 패키지에 대해 아래 Python 스크립트 실행** — 패키지명 목록을 공백으로 전달:

```bash
python3 - $FOUND_PACKAGES << 'PYEOF'
import sys, json, urllib.request, urllib.error, datetime, os, re

packages = sys.argv[1:]
if not packages:
    print("[ERROR] 비교할 패키지가 없습니다.")
    sys.exit(1)

print(f"\n{'='*60}")
print(f"  PyPI 패키지 비교 검색: {', '.join(packages)}")
print(f"{'='*60}\n")

results = []

for pkg_name in packages:
    pkg_name = pkg_name.strip().lower()
    if not pkg_name:
        continue

    print(f"  조회 중: {pkg_name}...", end=" ", flush=True)

    # PyPI JSON API
    try:
        url = f"https://pypi.org/pypi/{pkg_name}/json"
        req = urllib.request.Request(url, headers={"User-Agent": "nco-search-pypi/1.0"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode())
        info = data.get("info", {})
    except urllib.error.HTTPError:
        print("NOT FOUND")
        continue
    except Exception as e:
        print(f"ERROR ({e})")
        continue

    # pypistats
    dl_month = 0
    try:
        stats_url = f"https://pypistats.org/api/packages/{pkg_name}/recent"
        req2 = urllib.request.Request(stats_url, headers={"User-Agent": "nco-search-pypi/1.0"})
        with urllib.request.urlopen(req2, timeout=8) as resp2:
            stats = json.loads(resp2.read().decode())
        dl_month = stats.get("data", {}).get("last_month", 0)
    except Exception:
        pass

    name = info.get("name", pkg_name)
    version = info.get("version", "?")
    summary = info.get("summary", "")
    author = info.get("author") or info.get("maintainer") or "?"
    license_name = info.get("license") or "?"
    if license_name and len(license_name) > 40:
        license_name = license_name.split("\n")[0][:40]
    requires_python = info.get("requires_python") or "?"
    project_urls = info.get("project_urls") or {}

    github_url = ""
    for label, u in project_urls.items():
        if u and "github.com" in u.lower():
            github_url = u
            break

    results.append({
        "name": name,
        "version": version,
        "summary": summary[:120],
        "author": author,
        "license": license_name,
        "requires_python": requires_python,
        "dl_month": dl_month,
        "github": github_url,
        "pypi_url": f"https://pypi.org/project/{name}/",
    })
    print("OK")

if not results:
    print("\n[ERROR] 유효한 패키지를 찾지 못했습니다.")
    sys.exit(1)

# 다운로드 수 내림차순 정렬
results.sort(key=lambda r: r["dl_month"], reverse=True)

# ── 보고서 생성 ──
report_lines = []
query_str = " ".join(packages)
report_lines.append(f"# PyPI 검색 결과: {query_str}")
report_lines.append(f"")
report_lines.append(f"조회일: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M')} | 패키지 수: {len(results)}개")
report_lines.append(f"")

# 비교 테이블
report_lines.append(f"## 비교표")
report_lines.append(f"")
report_lines.append(f"| 패키지 | 버전 | 월간 DL | Python | 라이선스 |")
report_lines.append(f"|--------|------|---------|--------|---------|")
for r in results:
    dl_str = f"{r['dl_month']:,}" if r['dl_month'] else "?"
    report_lines.append(f"| [{r['name']}]({r['pypi_url']}) | {r['version']} | {dl_str} | {r['requires_python']} | {r['license']} |")
report_lines.append(f"")

# 개별 상세
report_lines.append(f"## 상세 정보")
report_lines.append(f"")
for i, r in enumerate(results, 1):
    report_lines.append(f"### {i}. {r['name']}")
    report_lines.append(f"- **설명**: {r['summary']}")
    report_lines.append(f"- **작성자**: {r['author']}")
    report_lines.append(f"- **버전**: {r['version']}")
    report_lines.append(f"- **월간 다운로드**: {r['dl_month']:,}" if r['dl_month'] else f"- **월간 다운로드**: ?")
    if r['github']:
        report_lines.append(f"- **GitHub**: {r['github']}")
    report_lines.append(f"- **설치**: `pip install {r['name']}`")
    report_lines.append(f"")

report = "\n".join(report_lines)

# ── 콘솔 출력 ──
print(f"\n{report}")

# ── 파일 저장 ──
safe_query = re.sub(r'[^a-zA-Z0-9_-]', '_', query_str)[:60]
ts = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
out_dir = os.path.join(os.getcwd(), "docs", "search")
os.makedirs(out_dir, exist_ok=True)
out_path = os.path.join(out_dir, f"{ts}-pypi-search-{safe_query}.md")
with open(out_path, "w", encoding="utf-8") as f:
    f.write(report)
print(f"\n[SAVED] {out_path}")
PYEOF
```

---

## STEP 3: 실행 흐름 요약

1. **STEP 1** bash를 실행하여 모드(DIRECT / SEARCH)를 판별한다.
2. **DIRECT 모드**: STEP 2A Python 스크립트를 바로 실행한다. 단일 패키지 상세 + 다운로드 통계를 조회하고 보고서를 저장한다.
3. **SEARCH 모드**: WebSearch 도구로 `site:pypi.org $ARGUMENTS` 검색 → 결과에서 패키지명 추출 → STEP 2B Python 스크립트에 패키지명 목록을 전달하여 비교 보고서를 생성한다.
4. 보고서는 `docs/search/YYYYMMDD-HHMMSS-pypi-*.md`에 자동 저장된다.

---

## 주의사항

- PyPI에는 JSON 검색 API가 없다. `https://pypi.org/search/?q=` 는 HTML만 반환하므로 curl로 파싱 불가.
- SEARCH 모드에서는 반드시 **WebSearch 도구**를 사용하여 패키지 후보를 찾는다.
- pypistats.org API는 rate limit이 있으므로 한 번에 10개 이상 패키지를 조회하지 않는다.
- WSL/Debian 환경에서 `pip install` 시 externally-managed-environment 에러가 발생할 수 있다. `uv add` 또는 가상환경을 권장한다.
