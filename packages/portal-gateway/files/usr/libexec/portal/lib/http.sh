#!/bin/sh
# =========================================================
# Portal HTTP helper
# =========================================================

# Usage:
#   portal_http_request METHOD URL [HEADERS] [BODY]
#
# HEADERS:
#   multi-line string:
#     Header-A: xxx
#     Header-B: yyy
#

portal_http_request() {
    method="$1"
    url="$2"
    headers="$3"
    body="$4"

    set -- -fsS --max-time 3 -X "$method" "$url"

    if [ -n "$headers" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            set -- "$@" -H "$line"
        done <<EOF
$headers
EOF
    fi

    [ -n "$body" ] && set -- "$@" --data "$body"

    curl "$@"
}