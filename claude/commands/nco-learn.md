# NCO 지식 베이스를 검색합니다.
# $ARGUMENTS를 검색 키워드로 사용합니다.
# 형식: /nco-learn <검색 키워드>

curl -s "http://localhost:6200/api/learn/query?keywords=$(echo $ARGUMENTS | sed 's/ /%20/g')" | python3 -m json.tool
