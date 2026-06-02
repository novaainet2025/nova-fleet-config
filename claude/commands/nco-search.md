# NCO 통합 검색 — 멀티소스 지능형 검색 엔진
# 형식: /nco-search [소스:] <검색어>
# 소스 옵션: github | hf | youtube | wiki | mcp | npm | pypi | skill | 없으면 웹 전체
#
# 예시:
#   /nco-search vllm 최신 양자화 기법
#   /nco-search github: mcp server typescript
#   /nco-search hf: Qwen2.5 7B quantized
#   /nco-search youtube: claude code tutorial
#   /nco-search wiki: transformer architecture
#   /nco-search mcp: filesystem tools
#   /nco-search npm: langchain tools
#   /nco-search pypi: sentence-transformers
#   /nco-search skill: 검색 관련 nco 스킬

## 소스 라우팅

$ARGUMENTS의 첫 토큰에서 `소스:` 접두어를 감지하여 전문 검색 스킬로 분기한다.

```bash
_ARGS="$ARGUMENTS"
# 소스 접두어 추출 (콜론 앞부분)
_PREFIX=$(echo "$_ARGS" | grep -oE '^[a-zA-Z]+:' | tr -d ':' | tr '[:upper:]' '[:lower:]')
_QUERY=$(echo "$_ARGS" | sed -E 's/^[a-zA-Z]+:\s*//')

# 접두어 없으면 원본 쿼리 사용
if [ -z "$_PREFIX" ]; then
  _QUERY="$_ARGS"
fi

case "$_PREFIX" in
  github|gh)
    echo "[라우팅] GitHub 전문 검색 → /nco-search-github"
    echo "쿼리: $_QUERY"
    echo ""
    echo "전문 검색 스킬을 호출합니다: /nco-search-github $_QUERY"
    ;;
  hf|huggingface)
    echo "[라우팅] Hugging Face 전문 검색 → /nco-search-hf"
    echo "쿼리: $_QUERY"
    echo ""
    echo "전문 검색 스킬을 호출합니다: /nco-search-hf $_QUERY"
    ;;
  youtube|yt)
    echo "[라우팅] YouTube 전문 검색 → /nco-search-youtube"
    echo "쿼리: $_QUERY"
    echo ""
    echo "전문 검색 스킬을 호출합니다: /nco-search-youtube $_QUERY"
    ;;
  wiki|wikipedia)
    echo "[라우팅] Wikipedia 전문 검색 → /nco-search-wiki"
    echo "쿼리: $_QUERY"
    echo ""
    echo "전문 검색 스킬을 호출합니다: /nco-search-wiki $_QUERY"
    ;;
  mcp)
    echo "[라우팅] MCP 서버/도구 검색 → /nco-search-mcp"
    echo "쿼리: $_QUERY"
    echo ""
    echo "전문 검색 스킬을 호출합니다: /nco-search-mcp $_QUERY"
    ;;
  npm|node)
    echo "[라우팅] npm 패키지 검색 → /nco-search-npm"
    echo "쿼리: $_QUERY"
    echo ""
    echo "전문 검색 스킬을 호출합니다: /nco-search-npm $_QUERY"
    ;;
  pypi|pip)
    echo "[라우팅] PyPI 패키지 검색 → /nco-search-pypi"
    echo "쿼리: $_QUERY"
    echo ""
    echo "전문 검색 스킬을 호출합니다: /nco-search-pypi $_QUERY"
    ;;
  skill)
    echo "[라우팅] NCO 로컬 스킬 검색"
    echo "쿼리: $_QUERY"
    echo ""
    echo "── 매칭 스킬 ──"
    for f in ~/.claude/commands/nco-*.md; do
      name=$(basename "$f" .md)
      desc=$(head -1 "$f" | sed 's/^# //')
      if echo "$name $desc" | grep -qi "$_QUERY"; then
        printf "  %-24s %s\n" "/$name" "$desc"
      fi
    done
    echo ""
    echo "── 내용 매칭 ──"
    grep -li "$_QUERY" ~/.claude/commands/nco-*.md 2>/dev/null | while read f; do
      name=$(basename "$f" .md)
      line=$(grep -i "$_QUERY" "$f" | head -1 | sed 's/^[# ]*//' | cut -c1-80)
      echo "  /$name: $line"
    done
    ;;
  *)
    # 웹 전체 통합 검색 모드
    echo "[통합 검색 모드]"
    echo "쿼리: $_QUERY"
    echo ""
    echo "소스 접두어가 없어 웹 전체 통합 검색을 실행합니다."
    echo ""
    echo "WebSearch 도구로 다음 쿼리를 순차 실행하세요:"
    echo "  1. WebSearch: $_QUERY"
    echo "  2. WebSearch: $_QUERY (영문 변환)"
    echo "  3. WebSearch: site:github.com $_QUERY"
    echo ""
    echo "결과에서 소스를 식별하면 전문 검색으로 전환:"
    echo "  GitHub 저장소 → /nco-search github: $_QUERY"
    echo "  npm 패키지   → /nco-search npm: $_QUERY"
    echo "  Python 패키지 → /nco-search pypi: $_QUERY"
    echo "  HF 모델      → /nco-search hf: $_QUERY"
    ;;
esac

# 검색 이력 저장
mkdir -p docs/search 2>/dev/null
echo "$(date '+%Y-%m-%d %H:%M:%S') | source:${_PREFIX:-web} | query:${_QUERY}" >> docs/search/search-history.log 2>/dev/null

# NCO 지식 베이스 등록
curl -s -X POST http://localhost:6200/api/learn/save \
  -H "Content-Type: application/json" \
  -d "{\"projectPath\":\"$(pwd)\",\"category\":\"search\",\"content\":\"[검색] source=${_PREFIX:-web} query=${_QUERY}\",\"confidence\":0.5}" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'KB 등록: {d.get(\"id\",\"OK\")}')" 2>/dev/null || true
```

---

## 사용 가능한 검색 소스 인덱스

| 소스 접두어 | 대상 | 예시 |
|------------|------|------|
| `github:` / `gh:` | GitHub 저장소/코드/이슈 | `/nco-search github: mcp typescript` |
| `hf:` / `huggingface:` | Hugging Face 모델/데이터셋 | `/nco-search hf: Qwen2.5 7B` |
| `youtube:` / `yt:` | YouTube 영상 | `/nco-search yt: vllm tutorial` |
| `wiki:` / `wikipedia:` | Wikipedia | `/nco-search wiki: RAG retrieval` |
| `mcp:` | MCP 서버/도구 | `/nco-search mcp: database tools` |
| `npm:` / `node:` | Node.js 패키지 | `/nco-search npm: openai sdk` |
| `pypi:` / `pip:` | Python 패키지 | `/nco-search pip: llama-index` |
| `skill:` | NCO 로컬 스킬 | `/nco-search skill: vllm` |
| _(없음)_ | 웹 전체 통합 | `/nco-search 최신 LLM 동향` |
