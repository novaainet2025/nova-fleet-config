# NCO MCP 서버/도구 전문 검색 — MCP 서버 · 도구 · 설정
# 형식: /nco-search-mcp <검색어> [--type server|tool|config|example]
# 예: /nco-search-mcp filesystem database
# 예: /nco-search-mcp --type server browser automation
# 예: /nco-search-mcp --type config claude desktop setup
# 예: /nco-search-mcp --type example web scraping

## STEP 1: 인수 파싱 및 검색 타입 결정

```bash
# Parse $ARGUMENTS for --type flag and query
ARGS="$ARGUMENTS"
SEARCH_TYPE="server"
QUERY=""

# Extract --type flag
if echo "$ARGS" | grep -q -- '--type'; then
  SEARCH_TYPE=$(echo "$ARGS" | sed -n 's/.*--type[= ]\+\([a-z]\+\).*/\1/p')
  ARGS=$(echo "$ARGS" | sed 's/--type[= ]\+[a-z]\+//g')
fi

# Remaining args become query (trim whitespace)
QUERY=$(echo "$ARGS" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

# Validate
if [ -z "$QUERY" ]; then
  echo "[ERROR] 검색어가 필요합니다."
  echo "사용법: /nco-search-mcp <검색어> [--type server|tool|config|example]"
  exit 1
fi

case "$SEARCH_TYPE" in
  server|tool|config|example) ;;
  *) echo "[WARN] 알 수 없는 타입 '$SEARCH_TYPE', 기본값 'server' 사용"; SEARCH_TYPE="server" ;;
esac

echo "============================================"
echo " MCP 검색 시작"
echo " 쿼리: $QUERY"
echo " 타입: $SEARCH_TYPE"
echo "============================================"
```

## STEP 2: npm 레지스트리 검색

```bash
QUERY_ENCODED=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$QUERY")
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')

echo ""
echo "[1/3] npm 레지스트리 검색..."

# Search npm for "mcp server <query>"
NPM_GENERAL=$(curl -sf --max-time 15 \
  "https://registry.npmjs.org/-/v1/search?text=mcp+server+${QUERY_ENCODED}&size=10" 2>/dev/null) || NPM_GENERAL="{}"

# Search npm for "@modelcontextprotocol <query>"
NPM_OFFICIAL=$(curl -sf --max-time 15 \
  "https://registry.npmjs.org/-/v1/search?text=%40modelcontextprotocol+${QUERY_ENCODED}&size=10" 2>/dev/null) || NPM_OFFICIAL="{}"

echo "[1/3] npm 검색 완료"

echo "[2/3] GitHub 저장소 검색..."

GH_RESULTS=$(curl -sf --max-time 15 \
  -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/search/repositories?q=mcp-server+${QUERY_ENCODED}&sort=stars&per_page=10" 2>/dev/null) || GH_RESULTS="{}"

echo "[2/3] GitHub 검색 완료"

echo "[3/3] 결과 분석 중..."
echo ""

# 임시 파일로 전달
_TMP_NPM=$(mktemp /tmp/nco-mcp-npm-XXXXXX.json)
_TMP_NPM2=$(mktemp /tmp/nco-mcp-npm2-XXXXXX.json)
_TMP_GH=$(mktemp /tmp/nco-mcp-gh-XXXXXX.json)
echo "$NPM_GENERAL" > "$_TMP_NPM"
echo "$NPM_OFFICIAL" > "$_TMP_NPM2"
echo "$GH_RESULTS" > "$_TMP_GH"
export QUERY SEARCH_TYPE

python3 - "$_TMP_NPM" "$_TMP_NPM2" "$_TMP_GH" << 'PYEOF'
import json, sys, os
from datetime import datetime

query = os.environ.get("QUERY", "unknown")
search_type = os.environ.get("SEARCH_TYPE", "server")

def read_json_file(path):
    try:
        with open(path) as f:
            return json.load(f)
    except: return {}

npm_general = read_json_file(sys.argv[1]) if len(sys.argv) > 1 else {}
npm_official = read_json_file(sys.argv[2]) if len(sys.argv) > 2 else {}
gh_data = read_json_file(sys.argv[3]) if len(sys.argv) > 3 else {}

# --- Safe JSON parse ---
def safe_json(raw, label):
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        print(f"[WARN] {label} JSON 파싱 실패, 건너뜀")
        return {}

# npm_general, npm_official, gh_data already loaded as dicts above

# --- Collect npm packages (deduplicated) ---
seen_npm = set()
npm_packages = []

for source in [npm_official, npm_general]:
    for obj in source.get("objects", []):
        pkg = obj.get("package", {})
        name = pkg.get("name", "")
        if not name or name in seen_npm:
            continue
        seen_npm.add(name)
        npm_packages.append({
            "name": name,
            "version": pkg.get("version", "?"),
            "description": (pkg.get("description") or "")[:80],
            "url": pkg.get("links", {}).get("npm", ""),
            "date": pkg.get("date", "")[:10],
        })

# --- Collect GitHub repos (deduplicated) ---
seen_gh = set()
gh_repos = []

for item in gh_data.get("items", []):
    full_name = item.get("full_name", "")
    if not full_name or full_name in seen_gh:
        continue
    seen_gh.add(full_name)
    gh_repos.append({
        "full_name": full_name,
        "stars": item.get("stargazers_count", 0),
        "description": (item.get("description") or "")[:80],
        "url": item.get("html_url", ""),
        "language": item.get("language") or "?",
    })

# --- Sort GitHub by stars ---
gh_repos.sort(key=lambda x: x["stars"], reverse=True)

# --- Build report ---
lines = []
lines.append(f"# MCP 검색 결과: {query}")
lines.append(f"검색일: {datetime.now().strftime('%Y-%m-%d %H:%M')} | 타입: {search_type}")
lines.append(f"소스: npm registry + GitHub API")
lines.append("")

# npm section
lines.append(f"## npm 패키지 ({len(npm_packages)}건)")
if npm_packages:
    lines.append("")
    lines.append("| # | 패키지 | 버전 | 설명 | 업데이트 |")
    lines.append("|---|--------|------|------|----------|")
    for i, p in enumerate(npm_packages[:15], 1):
        name_link = f"[{p['name']}]({p['url']})" if p['url'] else p['name']
        lines.append(f"| {i} | {name_link} | {p['version']} | {p['description']} | {p['date']} |")
else:
    lines.append("(결과 없음)")
lines.append("")

# GitHub section
lines.append(f"## GitHub 저장소 ({len(gh_repos)}건)")
if gh_repos:
    lines.append("")
    lines.append("| # | 저장소 | Stars | 언어 | 설명 |")
    lines.append("|---|--------|-------|------|------|")
    for i, r in enumerate(gh_repos[:15], 1):
        name_link = f"[{r['full_name']}]({r['url']})" if r['url'] else r['full_name']
        lines.append(f"| {i} | {name_link} | {r['stars']} | {r['language']} | {r['description']} |")
else:
    lines.append("(결과 없음)")
lines.append("")

# Installation section
lines.append("## 설치 방법")
lines.append("")

if npm_packages:
    top = npm_packages[0]
    pkg_name = top["name"]
    short_name = pkg_name.split("/")[-1].replace("server-", "").replace("mcp-", "")

    FENCE = chr(96)*3
    lines.append("### Claude Code")
    lines.append(f"{FENCE}bash")
    lines.append(f'claude mcp add {short_name} -- npx -y {pkg_name}')
    lines.append(FENCE)
    lines.append("")
    lines.append("### Claude Desktop (claude_desktop_config.json)")
    lines.append(f"{FENCE}json")
    lines.append(json.dumps({
        "mcpServers": {
            short_name: {
                "command": "npx",
                "args": ["-y", pkg_name]
            }
        }
    }, indent=2))
    lines.append(FENCE)
else:
    lines.append("(npm 패키지가 없어 설치 예시를 생략합니다)")
lines.append("")

# Cross-search suggestions
lines.append("## 추가 검색")
lines.append(f"- `/nco-search-npm mcp {query}` -- npm 심화 검색")
lines.append(f"- `/nco-search-github mcp-server {query}` -- GitHub 코드 검색")
lines.append(f"- `/nco-search-pypi mcp {query}` -- Python MCP 패키지")
lines.append("")

report = "\n".join(lines)
print(report)

# Export report for file save
with open("/tmp/_mcp_search_report.md", "w") as f:
    f.write(report)

# Summary counts
total = len(npm_packages) + len(gh_repos)
print(f"\n--- 총 {total}건 (npm {len(npm_packages)} + GitHub {len(gh_repos)}) ---")

PYEOF

# Cleanup temp files
rm -f "$_TMP_NPM" "$_TMP_NPM2" "$_TMP_GH"
mkdir -p docs/search

SLUG=$(echo "$QUERY" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')
REPORT_FILE="docs/search/${TIMESTAMP}-mcp-${SLUG}.md"

if [ -f /tmp/_mcp_search_report.md ]; then
  cp /tmp/_mcp_search_report.md "$REPORT_FILE"
  rm -f /tmp/_mcp_search_report.md
  echo ""
  echo "보고서 저장: $REPORT_FILE"
else
  echo "[WARN] 보고서 파일 생성 실패"
fi
```
