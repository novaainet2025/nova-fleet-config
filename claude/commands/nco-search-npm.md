# NCO npm 패키지 전문 검색 — Node.js · TypeScript · JavaScript 라이브러리
# 형식: /nco-search-npm <패키지명 또는 기능>
# 예: /nco-search-npm openai sdk typescript
# 예: /nco-search-npm web scraping headless browser
# 예: /nco-search-npm llm streaming response
# 예: /nco-search-npm "@anthropic-ai/sdk"
#
# API:
#   - npm 레지스트리: registry.npmjs.org (무료)
#   - npm 다운로드 통계: api.npmjs.org/downloads (무료)

```bash
#!/usr/bin/env bash
set -euo pipefail

QUERY="$ARGUMENTS"
if [ -z "$QUERY" ]; then
  echo "ERROR: 검색어를 입력하세요. 예: /nco-search-npm express"
  exit 1
fi

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
REPORT_DIR="docs/search"
mkdir -p "$REPORT_DIR"

TRIMMED="$(echo "$QUERY" | xargs)"

# Detect mode: exact package name vs search query
# Exact if: scoped package (@scope/name) or single word (no spaces)
IS_EXACT="false"
if echo "$TRIMMED" | grep -qP '^@[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$'; then
  IS_EXACT="true"
elif echo "$TRIMMED" | grep -qP '^[a-zA-Z0-9._-]+$'; then
  IS_EXACT="true"
fi

# Temp files for API responses
PKG_FILE=$(mktemp)
DL_FILE=$(mktemp)
SEARCH_FILE=$(mktemp)
DL_DIR=$(mktemp -d)
DL_MERGED=$(mktemp)
trap 'rm -f "$PKG_FILE" "$DL_FILE" "$SEARCH_FILE" "$DL_MERGED"; rm -rf "$DL_DIR"' EXIT

# ── EXACT PACKAGE LOOKUP ──
if [ "$IS_EXACT" = "true" ]; then
  echo "[npm 직접 조회] 패키지: $TRIMMED"
  echo "---"

  curl -sf "https://registry.npmjs.org/${TRIMMED}/latest" > "$PKG_FILE" 2>/dev/null || true
  curl -sf "https://api.npmjs.org/downloads/point/last-month/${TRIMMED}" > "$DL_FILE" 2>/dev/null || true

  if [ ! -s "$PKG_FILE" ] || grep -q '"error"' "$PKG_FILE" 2>/dev/null; then
    echo "ERROR: 패키지 '$TRIMMED'을(를) 찾을 수 없습니다."
    echo "검색 모드로 전환합니다..."
    echo ""
    IS_EXACT="false"
  fi
fi

if [ "$IS_EXACT" = "true" ]; then
  SAFE_NAME="${TRIMMED//\//-}"
  REPORT_FILE="${REPORT_DIR}/${TIMESTAMP}-npm-${SAFE_NAME}.md"

  python3 - "$PKG_FILE" "$DL_FILE" "$TRIMMED" << 'PYEOF' | tee "$REPORT_FILE"
import json, sys, datetime

pkg_path, dl_path, pkg_name = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    with open(pkg_path) as f:
        pkg = json.load(f)
except Exception as e:
    print(f"ERROR: 패키지 JSON 파싱 실패: {e}")
    sys.exit(1)

try:
    with open(dl_path) as f:
        dl = json.load(f)
    downloads = f"{dl.get('downloads', 0):,}"
except:
    downloads = "N/A"

name = pkg.get("name", pkg_name)
version = pkg.get("version", "unknown")
desc = pkg.get("description", "설명 없음") or "설명 없음"
license_info = pkg.get("license", "N/A")
keywords = pkg.get("keywords", []) or []
kw_str = ", ".join(f"`{k}`" for k in keywords[:10]) if keywords else "없음"

homepage = pkg.get("homepage", "")
repo = pkg.get("repository", {})
repo_url = repo.get("url", "") if isinstance(repo, dict) else (repo if isinstance(repo, str) else "")

deps = pkg.get("dependencies", {}) or {}
dev_deps = pkg.get("devDependencies", {}) or {}
peer_deps = pkg.get("peerDependencies", {}) or {}

has_types = "types" in pkg or "typings" in pkg
ts_status = "Built-in" if has_types else f"Check @types/{name.lstrip('@').replace('/', '__')}"

now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")

lines = []
lines.append(f"# npm 패키지 조회: {name}")
lines.append(f"조회일: {now} | API: registry.npmjs.org")
lines.append("")
lines.append(f"## {name}")
lines.append(f"- **버전**: v{version}")
lines.append(f"- **설명**: {desc}")
lines.append(f"- **라이선스**: {license_info}")
lines.append(f"- **월간 다운로드**: {downloads}")
lines.append(f"- **TypeScript**: {ts_status}")
lines.append(f"- **의존성**: {len(deps)}개 (dev: {len(dev_deps)}개, peer: {len(peer_deps)}개)")
lines.append(f"- **키워드**: {kw_str}")
if homepage:
    lines.append(f"- **홈페이지**: {homepage}")
if repo_url:
    lines.append(f"- **저장소**: {repo_url}")
lines.append(f"- **npm**: https://www.npmjs.com/package/{name}")
lines.append("")

if deps:
    lines.append("### 주요 의존성")
    for d, v in sorted(deps.items())[:15]:
        lines.append(f"  - {d}: {v}")
    if len(deps) > 15:
        lines.append(f"  - ... 외 {len(deps) - 15}개")
    lines.append("")

lines.append("### 설치")
lines.append(chr(96)*3 + "bash")
lines.append(f"npm install {name}")
lines.append(f"pnpm add {name}")
lines.append(f"yarn add {name}")
lines.append(chr(96)*3)

print("\n".join(lines))
PYEOF

  echo ""
  echo "---"
  echo "보고서 저장: $REPORT_FILE"
  exit 0
fi

# ── SEARCH MODE ──
echo "[npm 검색] 쿼리: $TRIMMED"
echo "---"

ENCODED_QUERY=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$TRIMMED'))")

curl -sf "https://registry.npmjs.org/-/v1/search?text=${ENCODED_QUERY}&size=10&quality=0.65&popularity=0.98&maintenance=0.5" > "$SEARCH_FILE" 2>/dev/null || true

if [ ! -s "$SEARCH_FILE" ]; then
  echo "ERROR: npm 레지스트리 검색 API 호출 실패"
  exit 1
fi

# Extract package names and fetch downloads in parallel
PKG_NAMES=$(python3 -c "
import json, sys
try:
    with open('$SEARCH_FILE') as f:
        data = json.load(f)
    for obj in data.get('objects', []):
        print(obj['package']['name'])
except:
    pass
")

for pkg_name in $PKG_NAMES; do
  safe=$(echo "$pkg_name" | tr '/' '_')
  curl -sf "https://api.npmjs.org/downloads/point/last-month/${pkg_name}" > "${DL_DIR}/${safe}.json" 2>/dev/null &
done
wait

# Merge download JSONs into one file
for f in "${DL_DIR}"/*.json; do
  [ -f "$f" ] && cat "$f" && echo ""
done > "$DL_MERGED"

REPORT_FILE="${REPORT_DIR}/${TIMESTAMP}-npm-search.md"

python3 - "$SEARCH_FILE" "$DL_MERGED" "$TRIMMED" << 'PYEOF' | tee "$REPORT_FILE"
import json, sys, datetime

search_path, dl_path, query = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    with open(search_path) as f:
        search = json.load(f)
except Exception as e:
    print(f"ERROR: 검색 결과 파싱 실패: {e}")
    sys.exit(1)

# Parse download data (one JSON object per line)
dl_map = {}
try:
    with open(dl_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
                if "package" in d and "downloads" in d:
                    dl_map[d["package"]] = d["downloads"]
            except:
                pass
except:
    pass

objects = search.get("objects", [])
total = search.get("total", 0)
now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")

lines = []
lines.append(f"# npm 패키지 검색: {query}")
lines.append(f"검색일: {now} | 총 {total}건 중 상위 {len(objects)}건")
lines.append("")

if not objects:
    lines.append("검색 결과가 없습니다.")
    print("\n".join(lines))
    sys.exit(0)

# Detailed list
for i, obj in enumerate(objects, 1):
    p = obj["package"]
    name = p.get("name", "?")
    ver = p.get("version", "?")
    desc = p.get("description", "설명 없음") or "설명 없음"
    kws = p.get("keywords", []) or []
    date = p.get("date", "?")[:10] if p.get("date") else "?"
    npm_link = p.get("links", {}).get("npm", f"https://www.npmjs.com/package/{name}")

    score = obj.get("score", {})
    detail = score.get("detail", {})
    pop = detail.get("popularity", 0)
    qual = detail.get("quality", 0)
    maint = detail.get("maintenance", 0)

    dl_count = dl_map.get(name)
    dl_str = f"{dl_count:,}/월" if dl_count is not None else "N/A"

    kw_str = ", ".join(f"`{k}`" for k in kws[:6]) if kws else "없음"

    lines.append(f"## {i}. [{name}]({npm_link})")
    lines.append(f"- **버전**: v{ver} | **최근 업데이트**: {date}")
    lines.append(f"- **설명**: {desc}")
    lines.append(f"- **월간 다운로드**: {dl_str}")
    lines.append(f"- **점수**: 인기 {pop:.2f} | 품질 {qual:.2f} | 유지보수 {maint:.2f}")
    lines.append(f"- **키워드**: {kw_str}")
    lines.append("")

# Comparison table
lines.append("## 비교 테이블")
lines.append("| # | 패키지 | 버전 | 월간 DL | 인기 | 품질 | 유지보수 |")
lines.append("|---|--------|------|---------|------|------|---------|")
for i, obj in enumerate(objects, 1):
    p = obj["package"]
    name = p.get("name", "?")
    ver = p.get("version", "?")
    score = obj.get("score", {}).get("detail", {})
    dl_count = dl_map.get(name)
    dl_str = f"{dl_count:,}" if dl_count is not None else "N/A"
    lines.append(f"| {i} | {name} | {ver} | {dl_str} | {score.get('popularity',0):.2f} | {score.get('quality',0):.2f} | {score.get('maintenance',0):.2f} |")

lines.append("")
lines.append("## 설치 (상위 1위)")
top_name = objects[0]["package"]["name"]
lines.append(chr(96)*3 + "bash")
lines.append(f"npm install {top_name}")
lines.append(f"pnpm add {top_name}")
lines.append(f"yarn add {top_name}")
lines.append(chr(96)*3)

print("\n".join(lines))
PYEOF

echo ""
echo "---"
echo "보고서 저장: $REPORT_FILE"
```
