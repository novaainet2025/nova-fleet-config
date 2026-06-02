# NCO GitHub 전문 검색 — 저장소 · 코드 · 이슈 · 토픽
# 형식: /nco-search-github <검색어> [--type repo|code|issue|user|topic]
# 예: /nco-search-github mcp server typescript
# 예: /nco-search-github --type code "vllm tool_use"
# 예: /nco-search-github --type issue "anthropic rate limit"
#
# 무료 API: api.github.com (인증 없이 60req/hr, 토큰 있으면 5000req/hr)
# GitHub Token 설정: export GITHUB_TOKEN=<your_token>

```bash
_ARGS="$ARGUMENTS"

# Parse --type flag
_TYPE=$(echo "$_ARGS" | grep -oE '\-\-type\s+\w+' | awk '{print $2}')
_TYPE="${_TYPE:-repo}"
_QUERY=$(echo "$_ARGS" | sed -E 's/--type\s+\w+\s*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

if [ -z "$_QUERY" ]; then
  echo "오류: 검색어를 입력하세요."
  echo "사용법: /nco-search-github <검색어> [--type repo|code|issue|user|topic]"
  exit 1
fi

# URL encode query
_ENC_QUERY=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$_QUERY")

echo "# GitHub 검색: $_QUERY"
echo "타입: $_TYPE | $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Build auth header
_AUTH_HEADER=""
if [ -n "$GITHUB_TOKEN" ]; then
  _AUTH_HEADER="Authorization: Bearer $GITHUB_TOKEN"
  echo "[인증: 토큰 사용 (5000 req/hr)]"
else
  echo "[인증: 없음 (60 req/hr) — GITHUB_TOKEN 설정 권장]"
fi
echo ""

# Helper: curl with optional auth
_curl_gh() {
  if [ -n "$_AUTH_HEADER" ]; then
    curl -s -w "\n%{http_code}" -H "Accept: application/vnd.github+json" -H "$_AUTH_HEADER" "$1"
  else
    curl -s -w "\n%{http_code}" -H "Accept: application/vnd.github+json" "$1"
  fi
}

case "$_TYPE" in

  repo)
    echo "## 저장소 검색 (Stars 순)"
    echo ""
    _RESPONSE=$(_curl_gh "https://api.github.com/search/repositories?q=${_ENC_QUERY}&sort=stars&order=desc&per_page=10")
    _HTTP_CODE=$(echo "$_RESPONSE" | tail -1)
    _BODY=$(echo "$_RESPONSE" | sed '$d')

    if [ "$_HTTP_CODE" = "403" ]; then
      echo "오류: API 요청 제한 초과 (Rate Limit). GITHUB_TOKEN을 설정하거나 잠시 후 재시도하세요."
      exit 1
    elif [ "$_HTTP_CODE" != "200" ]; then
      echo "오류: GitHub API 응답 코드 $_HTTP_CODE"
      echo "$_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('message','알 수 없는 오류'))" 2>/dev/null
      exit 1
    fi

    echo "$_BODY" | python3 -c "
import sys, json

try:
    d = json.load(sys.stdin)
except json.JSONDecodeError as e:
    print(f'JSON 파싱 오류: {e}')
    sys.exit(1)

if 'message' in d and 'items' not in d:
    print(f'API 오류: {d[\"message\"]}')
    sys.exit(1)

items = d.get('items', [])
if not items:
    print('  결과 없음')
    sys.exit(0)

total = d.get('total_count', 0)
print(f'총 {total:,}개 중 상위 {len(items)}개\n')
print(f'{\"저장소\":<40} {\"Stars\":>8} {\"언어\":<12} {\"업데이트\":<12} {\"라이선스\":<10}')
print('-' * 90)
for r in items:
    name = r.get('full_name', '?')[:38]
    stars = r.get('stargazers_count', 0)
    lang = r.get('language', '?') or '?'
    updated = r.get('updated_at', '')[:10]
    lic = (r.get('license') or {}).get('spdx_id', '?')
    print(f'{name:<40} {stars:>8,} {lang:<12} {updated:<12} {lic:<10}')

print()

# Top 3 details
for r in items[:3]:
    print(f'### {r[\"full_name\"]}')
    print(f'  URL: {r[\"html_url\"]}')
    desc = r.get('description', '(없음)') or '(없음)'
    print(f'  설명: {desc[:120]}')
    print(f'  Stars: {r.get(\"stargazers_count\",0):,} | Forks: {r.get(\"forks_count\",0):,} | Issues: {r.get(\"open_issues_count\",0):,}')
    topics = r.get('topics', [])[:8]
    if topics:
        print(f'  토픽: {', '.join(topics)}')
    homepage = r.get('homepage', '')
    if homepage:
        print(f'  홈페이지: {homepage}')
    print()
"
    ;;

  code)
    echo "## 코드 검색"
    echo ""
    _RESPONSE=$(_curl_gh "https://api.github.com/search/code?q=${_ENC_QUERY}&per_page=15")
    _HTTP_CODE=$(echo "$_RESPONSE" | tail -1)
    _BODY=$(echo "$_RESPONSE" | sed '$d')

    if [ "$_HTTP_CODE" = "401" ] || [ "$_HTTP_CODE" = "403" ]; then
      echo "오류: 코드 검색은 GITHUB_TOKEN이 필수입니다."
      echo "설정: export GITHUB_TOKEN=<your_token>"
      echo ""
      echo "대안: WebSearch site:github.com $_QUERY"
      exit 1
    elif [ "$_HTTP_CODE" = "422" ]; then
      echo "오류: 코드 검색에는 GITHUB_TOKEN이 필요합니다."
      echo "설정: export GITHUB_TOKEN=<your_token>"
      exit 1
    elif [ "$_HTTP_CODE" != "200" ]; then
      echo "오류: GitHub API 응답 코드 $_HTTP_CODE"
      echo "$_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('message','알 수 없는 오류'))" 2>/dev/null
      exit 1
    fi

    echo "$_BODY" | python3 -c "
import sys, json

try:
    d = json.load(sys.stdin)
except json.JSONDecodeError as e:
    print(f'JSON 파싱 오류: {e}')
    sys.exit(1)

if 'message' in d and 'items' not in d:
    print(f'API 오류: {d[\"message\"]}')
    sys.exit(1)

items = d.get('items', [])
if not items:
    print('  결과 없음')
    sys.exit(0)

total = d.get('total_count', 0)
print(f'총 {total:,}개 중 상위 {len(items)}개\n')
print(f'{\"저장소\":<35} {\"파일 경로\":<50} {\"점수\":>6}')
print('-' * 95)
for r in items:
    repo = r.get('repository', {}).get('full_name', '?')[:33]
    path = r.get('path', '?')[:48]
    score = r.get('score', 0)
    print(f'{repo:<35} {path:<50} {score:>6.1f}')

print()

# Group by repository
repos = {}
for r in items:
    repo_name = r.get('repository', {}).get('full_name', '?')
    if repo_name not in repos:
        repos[repo_name] = []
    repos[repo_name].append(r)

print('### 저장소별 파일 분포')
for repo_name, files in sorted(repos.items(), key=lambda x: -len(x[1])):
    print(f'  {repo_name} ({len(files)}개 파일)')
    for f in files[:5]:
        url = f.get('html_url', '')
        path = f.get('path', '?')
        print(f'    - {path}')
        if url:
            print(f'      {url}')
    print()
"
    ;;

  issue)
    echo "## 이슈/PR 검색 (반응 수 순)"
    echo ""

    # Search issues
    _RESPONSE=$(_curl_gh "https://api.github.com/search/issues?q=${_ENC_QUERY}+is:issue&sort=reactions&order=desc&per_page=10")
    _HTTP_CODE=$(echo "$_RESPONSE" | tail -1)
    _BODY=$(echo "$_RESPONSE" | sed '$d')

    if [ "$_HTTP_CODE" = "403" ]; then
      echo "오류: API 요청 제한 초과 (Rate Limit)."
      exit 1
    elif [ "$_HTTP_CODE" != "200" ]; then
      echo "오류: GitHub API 응답 코드 $_HTTP_CODE"
      echo "$_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('message','알 수 없는 오류'))" 2>/dev/null
      exit 1
    fi

    echo "$_BODY" | python3 -c "
import sys, json

try:
    d = json.load(sys.stdin)
except json.JSONDecodeError as e:
    print(f'JSON 파싱 오류: {e}')
    sys.exit(1)

if 'message' in d and 'items' not in d:
    print(f'API 오류: {d[\"message\"]}')
    sys.exit(1)

items = d.get('items', [])
if not items:
    print('  이슈 결과 없음')
    sys.exit(0)

total = d.get('total_count', 0)
print(f'### 이슈 (총 {total:,}개 중 상위 {len(items)}개)\n')
print(f'{\"이슈\":<60} {\"상태\":<8} {\"반응\":>5} {\"댓글\":>5} {\"날짜\":<12}')
print('-' * 95)
for r in items:
    repo_url = r.get('repository_url', '')
    repo = repo_url.split('repos/')[-1] if 'repos/' in repo_url else ''
    number = r.get('number', '?')
    title = r.get('title', '?')[:40]
    label = f'{repo}#{number} {title}'[:58]
    state = r.get('state', '?')
    reactions = r.get('reactions', {}).get('total_count', 0)
    comments = r.get('comments', 0)
    created = r.get('created_at', '')[:10]
    print(f'{label:<60} {state:<8} {reactions:>5} {comments:>5} {created:<12}')

print()

# Top 5 details
for r in items[:5]:
    repo_url = r.get('repository_url', '')
    repo = repo_url.split('repos/')[-1] if 'repos/' in repo_url else ''
    number = r.get('number', '?')
    print(f'### {repo}#{number}: {r.get(\"title\", \"?\")[:80]}')
    print(f'  URL: {r.get(\"html_url\", \"?\")}')
    print(f'  상태: {r.get(\"state\", \"?\")} | 반응: {r.get(\"reactions\", {}).get(\"total_count\", 0)} | 댓글: {r.get(\"comments\", 0)}')
    labels = [l.get('name', '') for l in r.get('labels', [])[:5]]
    if labels:
        print(f'  라벨: {', '.join(labels)}')
    body = r.get('body', '') or ''
    if body:
        preview = body[:200].replace('\n', ' ').replace('\r', '')
        print(f'  내용: {preview}...')
    print()
"

    # Also search merged PRs
    echo ""
    echo "---"
    echo ""
    _RESPONSE2=$(_curl_gh "https://api.github.com/search/issues?q=${_ENC_QUERY}+is:pr+is:merged&sort=updated&order=desc&per_page=5")
    _HTTP_CODE2=$(echo "$_RESPONSE2" | tail -1)
    _BODY2=$(echo "$_RESPONSE2" | sed '$d')

    if [ "$_HTTP_CODE2" = "200" ]; then
      echo "$_BODY2" | python3 -c "
import sys, json

try:
    d = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(0)

items = d.get('items', [])
if not items:
    print('### 병합된 PR: 결과 없음')
    sys.exit(0)

total = d.get('total_count', 0)
print(f'### 병합된 PR (총 {total:,}개 중 상위 {len(items)}개)\n')
for r in items:
    repo_url = r.get('repository_url', '')
    repo = repo_url.split('repos/')[-1] if 'repos/' in repo_url else ''
    number = r.get('number', '?')
    title = r.get('title', '?')[:70]
    updated = r.get('updated_at', '')[:10]
    print(f'  [{repo}#{number}] {title}')
    print(f'    {r.get(\"html_url\", \"\")} ({updated})')
print()
"
    fi
    ;;

  user)
    echo "## 사용자/조직 검색"
    echo ""
    _RESPONSE=$(_curl_gh "https://api.github.com/search/users?q=${_ENC_QUERY}&per_page=10")
    _HTTP_CODE=$(echo "$_RESPONSE" | tail -1)
    _BODY=$(echo "$_RESPONSE" | sed '$d')

    if [ "$_HTTP_CODE" = "403" ]; then
      echo "오류: API 요청 제한 초과 (Rate Limit)."
      exit 1
    elif [ "$_HTTP_CODE" != "200" ]; then
      echo "오류: GitHub API 응답 코드 $_HTTP_CODE"
      exit 1
    fi

    echo "$_BODY" | python3 -c "
import sys, json

try:
    d = json.load(sys.stdin)
except json.JSONDecodeError as e:
    print(f'JSON 파싱 오류: {e}')
    sys.exit(1)

items = d.get('items', [])
if not items:
    print('  결과 없음')
    sys.exit(0)

total = d.get('total_count', 0)
print(f'총 {total:,}개 중 상위 {len(items)}개\n')
print(f'{\"사용자\":<30} {\"타입\":<15} {\"점수\":>8} {\"URL\"}')
print('-' * 90)
for r in items:
    login = r.get('login', '?')[:28]
    utype = r.get('type', '?')
    score = r.get('score', 0)
    url = r.get('html_url', '')
    print(f'{login:<30} {utype:<15} {score:>8.1f} {url}')
print()
"
    ;;

  topic)
    echo "## 토픽 검색"
    echo ""
    _RESPONSE=$(_curl_gh "https://api.github.com/search/topics?q=${_ENC_QUERY}&per_page=10")
    _HTTP_CODE=$(echo "$_RESPONSE" | tail -1)
    _BODY=$(echo "$_RESPONSE" | sed '$d')

    if [ "$_HTTP_CODE" = "403" ]; then
      echo "오류: API 요청 제한 초과 (Rate Limit)."
      exit 1
    elif [ "$_HTTP_CODE" != "200" ]; then
      echo "오류: GitHub API 응답 코드 $_HTTP_CODE"
      exit 1
    fi

    echo "$_BODY" | python3 -c "
import sys, json

try:
    d = json.load(sys.stdin)
except json.JSONDecodeError as e:
    print(f'JSON 파싱 오류: {e}')
    sys.exit(1)

items = d.get('items', [])
if not items:
    print('  결과 없음')
    sys.exit(0)

total = d.get('total_count', 0)
print(f'총 {total:,}개 중 상위 {len(items)}개\n')
for r in items:
    name = r.get('name', '?')
    display = r.get('display_name', name)
    desc = r.get('short_description', '') or r.get('description', '') or '(설명 없음)'
    curated = 'Curated' if r.get('curated', False) else ''
    featured = 'Featured' if r.get('featured', False) else ''
    tags = ' '.join(filter(None, [curated, featured]))
    print(f'### {display}' + (f' [{tags}]' if tags else ''))
    print(f'  이름: {name}')
    print(f'  설명: {desc[:150]}')
    created_by = r.get('created_by', '')
    if created_by:
        print(f'  생성: {created_by}')
    print(f'  URL: https://github.com/topics/{name}')
    print()
"
    ;;

  *)
    echo "오류: 알 수 없는 검색 타입 '$_TYPE'"
    echo "지원 타입: repo, code, issue, user, topic"
    exit 1
    ;;
esac

# Save report
mkdir -p docs/search 2>/dev/null
echo "$(date '+%Y-%m-%d %H:%M:%S') | github:$_TYPE | $_QUERY" >> docs/search/search-history.log 2>/dev/null
echo "---"
echo "검색 기록 저장: docs/search/search-history.log"
echo ""
echo "추가 검색:"
echo "  /nco-search-github --type code \"$_QUERY\""
echo "  /nco-search-github --type issue \"$_QUERY\""
echo "  /nco-search-github --type user \"$_QUERY\""
echo "  /nco-search-github --type topic \"$_QUERY\""
```
