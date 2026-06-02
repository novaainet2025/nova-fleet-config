# NCO Wikipedia/문서 전문 검색 — 개념 · 원리 · 역사 · 기술문서
# 형식: /nco-search-wiki <검색어> [--lang ko|en] [--type concept|history|tech]
# 예: /nco-search-wiki transformer architecture
# 예: /nco-search-wiki --lang ko 강화학습
# 예: /nco-search-wiki --type tech RLHF 원리

Wikipedia API를 사용하여 검색합니다. 아래 스크립트를 실행하세요.

```bash
#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 1. Parse arguments: --lang (ko|en, default: both), --type (concept|history|tech)
###############################################################################
RAW_ARGS="$ARGUMENTS"
LANG_OPT=""
TYPE_OPT=""
QUERY_PARTS=()

# Tokenize and parse
eval "TOKENS=($RAW_ARGS)" 2>/dev/null || TOKENS=($RAW_ARGS)
SKIP_NEXT=false
for i in "${!TOKENS[@]}"; do
  if $SKIP_NEXT; then SKIP_NEXT=false; continue; fi
  case "${TOKENS[$i]}" in
    --lang)  LANG_OPT="${TOKENS[$((i+1))]:-}"; SKIP_NEXT=true ;;
    --type)  TYPE_OPT="${TOKENS[$((i+1))]:-}"; SKIP_NEXT=true ;;
    --*)     ;; # ignore unknown flags
    *)       QUERY_PARTS+=("${TOKENS[$i]}") ;;
  esac
done

QUERY="${QUERY_PARTS[*]:-}"
if [[ -z "$QUERY" ]]; then
  echo "ERROR: 검색어가 지정되지 않았습니다."
  echo "사용법: /nco-search-wiki <검색어> [--lang ko|en] [--type concept|history|tech]"
  exit 1
fi

# Defaults
[[ -z "$LANG_OPT" ]] && LANG_OPT="both"
[[ -z "$TYPE_OPT" ]] && TYPE_OPT="concept"

echo "========================================"
echo " Wikipedia 검색"
echo "========================================"
echo " 쿼리: $QUERY"
echo " 언어: $LANG_OPT"
echo " 타입: $TYPE_OPT"
echo "========================================"
echo ""

###############################################################################
# 2. Search + Summarize via Wikipedia APIs, parse with python3
###############################################################################
REPORT_DIR="docs/search"
mkdir -p "$REPORT_DIR"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
REPORT_FILE="$REPORT_DIR/${TIMESTAMP}-wiki-${QUERY// /-}.md"
ENCODED_QUERY="$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$QUERY")"

export QUERY LANG_OPT TYPE_OPT ENCODED_QUERY REPORT_FILE

python3 << 'PYEOF'
import json, sys, os, urllib.request, urllib.parse, urllib.error, textwrap
from datetime import datetime

query = os.environ.get("QUERY", "")
lang_opt = os.environ.get("LANG_OPT", "both")
type_opt = os.environ.get("TYPE_OPT", "concept")
report_file = os.environ.get("REPORT_FILE", "report.md")

def api_get(url, timeout=15):
    """Fetch JSON from URL with error handling."""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "NCO-WikiSearch/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError, Exception) as e:
        print(f"  [WARN] API 호출 실패: {url[:80]}... — {e}", file=sys.stderr)
        return None

def search_wiki(lang, query, limit=5):
    """Search Wikipedia Action API."""
    encoded = urllib.parse.quote(query)
    url = (f"https://{lang}.wikipedia.org/w/api.php?"
           f"action=query&list=search&srsearch={encoded}"
           f"&format=json&srlimit={limit}&srprop=snippet|titlesnippet")
    data = api_get(url)
    if data and "query" in data and "search" in data["query"]:
        return data["query"]["search"]
    return []

def get_summary(lang, title):
    """Get page summary via REST API."""
    encoded_title = urllib.parse.quote(title.replace(" ", "_"))
    url = f"https://{lang}.wikipedia.org/api/rest_v1/page/summary/{encoded_title}"
    return api_get(url)

# Determine which languages to search
langs = []
if lang_opt == "ko":
    langs = ["ko", "en"]
elif lang_opt == "en":
    langs = ["en"]
else:  # both
    langs = ["en", "ko"]

results = {}  # lang -> {search_results, summary}

for lang in langs:
    print(f"\n--- {lang.upper()} Wikipedia 검색 중... ---")
    sr = search_wiki(lang, query)
    if not sr:
        print(f"  [{lang}] 검색 결과 없음")
        results[lang] = {"search": [], "summary": None}
        continue

    print(f"  [{lang}] {len(sr)}건 발견:")
    for i, r in enumerate(sr):
        # Strip HTML tags from snippet
        import re
        snippet = re.sub(r'<[^>]+>', '', r.get("snippet", ""))
        print(f"    {i+1}. {r['title']} — {snippet[:80]}")

    # Get summary of top result
    top_title = sr[0]["title"]
    print(f"\n  [{lang}] 요약 가져오기: {top_title}")
    summary = get_summary(lang, top_title)
    if summary:
        extract = summary.get("extract", "(요약 없음)")
        desc = summary.get("description", "")
        page_url = summary.get("content_urls", {}).get("desktop", {}).get("page", "")
        print(f"  제목: {summary.get('title', top_title)}")
        print(f"  설명: {desc}")
        print(f"  요약: {extract[:200]}{'...' if len(extract) > 200 else ''}")
        print(f"  URL:  {page_url}")
    else:
        print(f"  [{lang}] 요약 가져오기 실패")

    results[lang] = {"search": sr, "summary": summary}

###############################################################################
# 3. Build structured report
###############################################################################
print(f"\n\n========================================")
print(f" 보고서 생성 중...")
print(f"========================================\n")

lines = []
lines.append(f"# Wikipedia 검색: {query}")
lines.append(f"")
lines.append(f"- 검색일: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
lines.append(f"- 언어: {lang_opt}")
lines.append(f"- 타입: {type_opt}")
lines.append(f"- API: Wikipedia REST + Action API (무료)")
lines.append(f"")

# Main summary section
for lang in langs:
    r = results.get(lang, {})
    summary = r.get("summary")
    if not summary:
        continue

    title = summary.get("title", query)
    extract = summary.get("extract", "(요약 없음)")
    desc = summary.get("description", "")
    page_url = summary.get("content_urls", {}).get("desktop", {}).get("page", "")
    lang_label = "영문" if lang == "en" else "한국어"

    lines.append(f"## {lang_label} Wikipedia: {title}")
    lines.append(f"")
    if desc:
        lines.append(f"**설명**: {desc}")
        lines.append(f"")
    lines.append(f"> {extract}")
    lines.append(f"")
    if page_url:
        lines.append(f"출처: [{title}]({page_url})")
    lines.append(f"")

# Multilingual comparison table
if len([l for l in langs if results.get(l, {}).get("summary")]) > 1:
    lines.append(f"## 다국어 비교")
    lines.append(f"")
    lines.append(f"| 언어 | 제목 | 요약 |")
    lines.append(f"|------|------|------|")
    for lang in langs:
        r = results.get(lang, {})
        summary = r.get("summary")
        if not summary:
            continue
        lang_label = "영문" if lang == "en" else "한국어"
        title = summary.get("title", "")
        extract = summary.get("extract", "")[:120]
        lines.append(f"| {lang_label} | {title} | {extract} |")
    lines.append(f"")

# Related articles
for lang in langs:
    r = results.get(lang, {})
    sr = r.get("search", [])
    if len(sr) <= 1:
        continue
    import re
    lang_label = "영문" if lang == "en" else "한국어"
    lines.append(f"## 관련 항목 ({lang_label})")
    lines.append(f"")
    for item in sr[1:]:
        title = item["title"]
        snippet = re.sub(r'<[^>]+>', '', item.get("snippet", ""))[:100]
        encoded = urllib.parse.quote(title.replace(" ", "_"))
        url = f"https://{lang}.wikipedia.org/wiki/{encoded}"
        lines.append(f"- [{title}]({url}): {snippet}")
    lines.append(f"")

# Type-specific hints
lines.append(f"## 추가 검색 제안")
lines.append(f"")
if type_opt == "history":
    lines.append(f"- 역사/발전 과정 세부 사항은 Wikipedia 본문의 History 섹션을 참조하세요.")
elif type_opt == "tech":
    lines.append(f"- 기술적 세부사항은 Wikipedia 본문의 Technical details 섹션을 참조하세요.")
    lines.append(f"- arxiv.org 검색: https://arxiv.org/search/?query={urllib.parse.quote(query)}")
lines.append(f"- /nco-search-youtube {query} lecture (영상 강의)")
lines.append(f"- /nco-search-hf --type paper {query} (관련 논문)")
lines.append(f"- /nco-search-github {query} implementation (구현 코드)")
lines.append(f"")

report = "\n".join(lines)

# Write report
with open(report_file, "w", encoding="utf-8") as f:
    f.write(report)

print(report)
print(f"\n========================================")
print(f" 보고서 저장 완료: {report_file}")
print(f"========================================")
PYEOF
```
