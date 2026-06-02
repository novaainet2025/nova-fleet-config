# NCO YouTube 전문 검색 — 영상 · 튜토리얼 · 강의 검색
# 형식: /nco-search-youtube <검색어> [--type tutorial|lecture|demo|review]
# 예: /nco-search-youtube claude code tutorial 2025
# 예: /nco-search-youtube --type lecture transformer architecture
# 예: /nco-search-youtube vllm local deployment demo
#
# YouTube는 JS 렌더링 사이트여서 curl/WebFetch로 직접 검색 불가
# WebSearch 도구만이 유일한 신뢰 가능한 검색 방법

---

## STEP 1: 검색 파싱 및 쿼리 구성

```bash
_ARGS="$ARGUMENTS"
_TYPE=$(echo "$_ARGS" | grep -oE '\-\-type\s+\w+' | awk '{print $2}')
_TYPE="${_TYPE:-tutorial}"
_QUERY=$(echo "$_ARGS" | sed -E 's/--type\s+\w+\s*//')

echo "# YouTube 검색: $_QUERY"
echo "타입: $_TYPE | $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
echo "YouTube는 JS 렌더링 사이트여서 curl로 직접 검색이 불가합니다."
echo "WebSearch 도구를 사용하여 다음 쿼리를 실행하세요:"
echo ""

case "$_TYPE" in
  tutorial)
    echo "  1. WebSearch: site:youtube.com $_QUERY tutorial 2025"
    echo "  2. WebSearch: youtube $_QUERY beginner guide"
    ;;
  lecture)
    echo "  1. WebSearch: site:youtube.com $_QUERY lecture course"
    echo "  2. WebSearch: youtube $_QUERY university lecture 2024 2025"
    ;;
  demo)
    echo "  1. WebSearch: site:youtube.com $_QUERY demo live"
    echo "  2. WebSearch: youtube $_QUERY demonstration walkthrough"
    ;;
  review)
    echo "  1. WebSearch: site:youtube.com $_QUERY review comparison"
    echo "  2. WebSearch: youtube $_QUERY vs best 2025"
    ;;
  *)
    echo "  1. WebSearch: site:youtube.com $_QUERY"
    echo "  2. WebSearch: youtube $_QUERY 2024 2025"
    ;;
esac

# Korean content
echo "  3. WebSearch: site:youtube.com $_QUERY 한국어"
echo ""
echo "각 결과에서 다음을 추출하세요:"
echo "  - 제목, URL, 채널명, 업로드 날짜"
echo "  - 영상 설명/요약"
echo ""

mkdir -p docs/search 2>/dev/null
echo "$(date '+%Y-%m-%d %H:%M:%S') | youtube:$_TYPE | $_QUERY" >> docs/search/search-history.log 2>/dev/null
```

---

## STEP 2: WebSearch 실행

위 bash 출력에 표시된 쿼리들을 WebSearch 도구로 순차 실행한다:

1. **메인 검색**: `site:youtube.com` 쿼리로 YouTube 영상 직접 탐색
2. **보조 검색**: 타입별 키워드를 포함한 일반 검색으로 놓친 결과 보완
3. **한국어 검색**: 한국어 콘텐츠 별도 탐색

각 WebSearch 결과에서 YouTube URL(`youtube.com/watch?v=`)을 추출하고 제목, 채널명, 날짜, 설명을 수집한다.

> **주의**: `WebFetch`로 `youtube.com/results` 페이지를 가져오면 빈 결과가 반환된다. 반드시 `WebSearch`만 사용할 것.

---

## STEP 3: 결과 출력 템플릿

수집된 결과를 아래 형식으로 정리하여 출력한다:

```
# YouTube 검색: <query>
검색일: <날짜> | 타입: <tutorial/lecture/demo/review> | 방식: WebSearch

## 추천 영상 TOP 10

### 1. [영상 제목](https://youtube.com/watch?v=...)
- **채널**: <채널명>
- **업로드**: <날짜 또는 추정 기간>
- **타입**: 튜토리얼 / 강의 / 데모 / 리뷰
- **요약**: <영상 내용 2-3줄 요약>
- **추천 이유**: <왜 이 영상이 적합한지>

### 2. [영상 제목](https://youtube.com/watch?v=...)
- **채널**: <채널명>
- **업로드**: <날짜>
- **타입**: <타입>
- **요약**: <요약>
- **추천 이유**: <이유>

### 3-10. (동일 형식으로 계속)

---

## 한국어 콘텐츠

| # | 영상 제목 | 채널 | 날짜 | URL |
|---|---------|------|------|-----|
| 1 | <제목> | <채널> | <날짜> | <URL> |
| 2 | <제목> | <채널> | <날짜> | <URL> |

---

## 학습 경로 제안

쿼리 주제를 효과적으로 학습하기 위한 추천 시청 순서:

1. **입문** (0-1시간): [영상 제목](url) — 기본 개념 이해
2. **기초** (1-3시간): [영상 제목](url) — 핵심 기능 학습
3. **중급** (3-5시간): [영상 제목](url) — 실전 적용
4. **심화** (5시간+): [영상 제목](url) — 고급 패턴/최적화

---

## 관련 검색 제안

- /nco-search-youtube <심화 관련 주제 1>
- /nco-search-youtube --type lecture <이론적 배경>
- /nco-search-youtube --type demo <실습 관련>
- /nco-search wiki: <주제> (개념 학습)
- /nco-search github: <관련 코드>
```
