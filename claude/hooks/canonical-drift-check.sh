#!/bin/bash

LOCAL_DIR="${HOME}/.claude/hooks"
CANONICAL_DIR="${HOME}/nova-fleet-config/claude/hooks"
TPL=$(printf '%s%s%s' '{{' HOME '}}')

get_mtime() {
    if stat -f %m "$1" >/dev/null 2>&1; then
        stat -f %m "$1"
    else
        stat -c %Y "$1"
    fi
}

cleanup() {
    if [ -n "${TMP_FILES:-}" ]; then
        # shellcheck disable=SC2086
        rm -f $TMP_FILES
    fi
}

trap cleanup EXIT

drift_count=0

[ -d "$LOCAL_DIR" ] || exit 0
[ -d "$CANONICAL_DIR" ] || exit 0

for local_file in "$LOCAL_DIR"/*.sh; do
    [ -e "$local_file" ] || break

    base_name=$(basename "$local_file")
    canonical_file="${CANONICAL_DIR}/${base_name}"

    [ -f "$canonical_file" ] || continue

    compare_file="$canonical_file"
    if grep -Fq "$TPL" "$canonical_file"; then
        compare_file=$(mktemp "${TMPDIR:-/tmp}/canonical-drift-check.XXXXXX") || exit 1
        TMP_FILES="${TMP_FILES:+${TMP_FILES} }${compare_file}"
        sed "s|$TPL|$HOME|g" "$canonical_file" > "$compare_file"
    fi

    if cmp -s "$local_file" "$compare_file"; then
        continue
    fi

    local_mtime=$(get_mtime "$local_file") || exit 1
    canonical_mtime=$(get_mtime "$canonical_file") || exit 1

    if [ "$local_mtime" -gt "$canonical_mtime" ]; then
        printf '⚠️ [drift] %s — 로컬 편집이 canonical 미반영 (다음 fleet-sync 시 소실됨. nova-fleet-config에 커밋 필요)\n' "$base_name" >&2
        drift_count=$((drift_count + 1))
    fi
done

exit 0
