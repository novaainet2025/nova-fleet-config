# NCO Hugging Face 전문 검색 — 모델 · 데이터셋 · Spaces · 논문
# 형식: /nco-search-hf <검색어> [--type model|dataset|space|paper]
# 예: /nco-search-hf Qwen2.5 7B quantized
# 예: /nco-search-hf --type dataset korean instruction tuning
# 예: /nco-search-hf --type space text-to-image
# 예: /nco-search-hf --type paper RAG retrieval 2024
#
# 무료 API: huggingface.co/api (인증 없이 사용 가능)
# HF Token 설정 (더 많은 결과): export HF_TOKEN=<your_token>

---

## STEP 1: 인수 파싱 및 검색 타입 결정

```bash
# Parse --type flag and query from $ARGUMENTS
ARGS="$ARGUMENTS"
SEARCH_TYPE="model"
QUERY=""

# Extract --type if present
if echo "$ARGS" | grep -q -- '--type'; then
  SEARCH_TYPE=$(echo "$ARGS" | sed -n 's/.*--type[= ]\?\([a-z]*\).*/\1/p')
  QUERY=$(echo "$ARGS" | sed 's/--type[= ]\?[a-z]*//' | xargs)
else
  QUERY=$(echo "$ARGS" | xargs)
fi

# Validate type
case "$SEARCH_TYPE" in
  model|dataset|space|paper) ;;
  *) echo "[ERROR] Unknown type: $SEARCH_TYPE (allowed: model, dataset, space, paper)"; exit 1 ;;
esac

# Check query is not empty
if [ -z "$QUERY" ]; then
  echo "[ERROR] 검색어가 비어 있습니다. 사용법: /nco-search-hf <검색어> [--type model|dataset|space|paper]"
  exit 1
fi

echo "[HuggingFace 검색]"
echo "  쿼리: $QUERY"
echo "  타입: $SEARCH_TYPE"
```

---

## STEP 2: Hugging Face API 호출

### paper 타입인 경우 WebSearch 안내

`--type paper`인 경우 HF에 논문 전용 API가 없으므로, 아래 WebSearch를 사용하여 검색한다:

- `site:huggingface.co/papers <query>`
- `site:arxiv.org <query>`

결과를 마크다운 테이블로 정리하여 `docs/search/` 에 저장한다.

### model / dataset / space 타입 API 호출

```bash
# Build API URL based on type
ENCODED_QUERY=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$QUERY'))")

case "$SEARCH_TYPE" in
  model)
    API_URL="https://huggingface.co/api/models?search=${ENCODED_QUERY}&sort=downloads&direction=-1&limit=10"
    ;;
  dataset)
    API_URL="https://huggingface.co/api/datasets?search=${ENCODED_QUERY}&sort=downloads&direction=-1&limit=10"
    ;;
  space)
    API_URL="https://huggingface.co/api/spaces?search=${ENCODED_QUERY}&sort=likes&direction=-1&limit=10"
    ;;
  paper)
    echo "[INFO] --type paper: WebSearch를 사용합니다. API 호출을 건너뜁니다."
    mkdir -p docs/search
    REPORT="docs/search/$(date '+%Y%m%d-%H%M%S')-hf-paper-${QUERY// /-}.md"
    echo "# HF Paper Search: $QUERY" > "$REPORT"
    echo "" >> "$REPORT"
    echo "WebSearch로 검색해 주세요:" >> "$REPORT"
    echo "- site:huggingface.co/papers $QUERY" >> "$REPORT"
    echo "- site:arxiv.org $QUERY" >> "$REPORT"
    echo "[저장됨] $REPORT"
    exit 0
    ;;
esac

# Set auth header if HF_TOKEN is available
AUTH_HEADER=""
if [ -n "$HF_TOKEN" ]; then
  AUTH_HEADER="-H \"Authorization: Bearer $HF_TOKEN\""
fi

echo "[API] $API_URL"
RESPONSE=$(curl -s -f --max-time 15 $AUTH_HEADER "$API_URL" 2>&1)
CURL_EXIT=$?

if [ $CURL_EXIT -ne 0 ]; then
  echo "[ERROR] API 호출 실패 (exit code: $CURL_EXIT)"
  echo "$RESPONSE"
  exit 1
fi

# Verify we got valid JSON
echo "$RESPONSE" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null
if [ $? -ne 0 ]; then
  echo "[ERROR] API가 유효한 JSON을 반환하지 않았습니다."
  echo "$RESPONSE" | head -5
  exit 1
fi

echo "[OK] API 응답 수신 완료"

# 임시 파일에 저장
_TMP_RESP=$(mktemp /tmp/nco-hf-XXXXXX.json)
echo "$RESPONSE" > "$_TMP_RESP"
export SEARCH_TYPE QUERY

# Parse and format results with python3
python3 - "$_TMP_RESP" << 'PYEOF'
import json, sys, os
from datetime import datetime

search_type = os.environ.get("SEARCH_TYPE", "model")
query = os.environ.get("QUERY", "")

resp_file = sys.argv[1] if len(sys.argv) > 1 else ""
raw = ""
if resp_file and os.path.exists(resp_file):
    with open(resp_file) as f:
        raw = f.read()
if not raw:
    print("[ERROR] API 응답이 비어 있습니다.")
    sys.exit(1)

try:
    items = json.loads(raw)
except json.JSONDecodeError as e:
    print(f"[ERROR] JSON 파싱 실패: {e}")
    sys.exit(1)

if not isinstance(items, list):
    print(f"[ERROR] 예상과 다른 응답 형식: {type(items)}")
    sys.exit(1)

lines = []
now = datetime.now().strftime("%Y-%m-%d %H:%M")
lines.append(f"# HuggingFace {search_type.capitalize()} Search: {query}")
lines.append(f"검색일: {now} | API: huggingface.co/api")
lines.append(f"결과 수: {len(items)}개")
lines.append("")

def fmt_num(n):
    if n is None:
        return "-"
    if n >= 1_000_000:
        return f"{n/1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n/1_000:.1f}K"
    return str(n)

if search_type == "model":
    lines.append("| # | 모델 ID | 다운로드 | 좋아요 | 태스크 | 라이브러리 | 최종 수정 |")
    lines.append("|---|---------|---------|--------|--------|-----------|----------|")
    for i, m in enumerate(items, 1):
        mid = m.get("modelId", m.get("id", "?"))
        dl = fmt_num(m.get("downloads"))
        likes = fmt_num(m.get("likes"))
        task = m.get("pipeline_tag", "-") or "-"
        lib = m.get("library_name", "-") or "-"
        mod = (m.get("lastModified") or "-")[:10]
        link = f"[{mid}](https://huggingface.co/{mid})"
        lines.append(f"| {i} | {link} | {dl} | {likes} | {task} | {lib} | {mod} |")

elif search_type == "dataset":
    lines.append("| # | 데이터셋 ID | 다운로드 | 좋아요 | 태그 |")
    lines.append("|---|-----------|---------|--------|------|")
    for i, d in enumerate(items, 1):
        did = d.get("id", "?")
        dl = fmt_num(d.get("downloads"))
        likes = fmt_num(d.get("likes"))
        tags = ", ".join((d.get("tags") or [])[:5]) or "-"
        link = f"[{did}](https://huggingface.co/datasets/{did})"
        lines.append(f"| {i} | {link} | {dl} | {likes} | {tags} |")

elif search_type == "space":
    lines.append("| # | Space ID | 좋아요 | SDK |")
    lines.append("|---|---------|--------|-----|")
    for i, s in enumerate(items, 1):
        sid = s.get("id", "?")
        likes = fmt_num(s.get("likes"))
        sdk = s.get("sdk", "-") or "-"
        link = f"[{sid}](https://huggingface.co/spaces/{sid})"
        lines.append(f"| {i} | {link} | {likes} | {sdk} |")

output = "\n".join(lines)
print(output)

# Write to environment for STEP 4
report_name = f"{datetime.now().strftime('%Y%m%d-%H%M%S')}-hf-{search_type}-{query.replace(' ', '-')}.md"
with open("/tmp/_hf_search_report.md", "w") as f:
    f.write(output + "\n")
with open("/tmp/_hf_search_report_name.txt", "w") as f:
    f.write(report_name)

PYEOF

# Cleanup temp file
rm -f "$_TMP_RESP"

mkdir -p docs/search

REPORT_NAME=$(cat /tmp/_hf_search_report_name.txt 2>/dev/null)
if [ -z "$REPORT_NAME" ]; then
  REPORT_NAME="$(date '+%Y%m%d-%H%M%S')-hf-search.md"
fi

REPORT_PATH="docs/search/$REPORT_NAME"
cp /tmp/_hf_search_report.md "$REPORT_PATH" 2>/dev/null

if [ -f "$REPORT_PATH" ]; then
  echo ""
  echo "[저장 완료] $REPORT_PATH"
else
  echo "[WARNING] 보고서 저장 실패 — 위 출력을 참고하세요."
fi

# Cleanup
rm -f /tmp/_hf_search_report.md /tmp/_hf_search_report_name.txt
```

---

## 추가 검색 안내

- `/nco-search-hf --type dataset <관련 쿼리>` — 데이터셋 검색
- `/nco-search-hf --type space <관련 쿼리>` — Spaces 검색
- `/nco-search-hf --type paper <논문 주제>` — 논문 검색 (WebSearch)
- `/nco-search github: <modelId>` — GitHub 관련 코드 검색
