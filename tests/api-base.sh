#!/usr/bin/env bash
# The API base the browser is given. This broke twice in one day and cost more
# time than anything else, so it is pinned.
set -uo pipefail
SRC="$(dirname "$(dirname "$(readlink -f "$0")")")"
PASS=0; FAIL=0
check() { [[ "$2" == "$3" ]] && { echo "  PASS  $1"; PASS=$((PASS+1)); } || { echo "  FAIL  $1: expected '$2', got '$3'"; FAIL=$((FAIL+1)); }; }

d="$(mktemp -d)"
probe() { # domain
  COMPOSE_DIR="$d" bash -c '
    COMPOSE_DIR="'"$d"'"
    '"$(sed -n '/^deployment_scheme() {/,/^}/p;/^api_base_for() {/,/^}/p' "$SRC/scripts/caytu-client")"'
    api_base_for "'"$1"'"
  '
}

echo
echo "the api base the browser is given"

# The bug: the client prepends /api itself, so a base carrying it produced
# /api/api/ and every request went to a path that does not exist.
check "is the origin, with nothing after it" \
  "http://binseven.caytu.link" "$(probe binseven.caytu.link)"
check "never ends in /api" "" "$(probe binseven.caytu.link | grep -o '/api$' || true)"

# http until a certificate exists, so the console never links to a port
# nothing is listening on.
mkdir -p "$d/certbot/conf/live/binseven.caytu.link"
touch "$d/certbot/conf/live/binseven.caytu.link/fullchain.pem"
check "https once a certificate is there" \
  "https://binseven.caytu.link" "$(probe binseven.caytu.link)"

check "empty for the template placeholder" "" "$(probe example.com)"
check "empty when there is no domain" "" "$(probe "")"

rm -rf "$d"
echo
printf '  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
