#!/usr/bin/env bash
# Which platform a machine talks to. Pinned because getting it wrong is silent:
# the agent polls happily and 404s forever.
set -uo pipefail
SRC="$(dirname "$(dirname "$(readlink -f "$0")")")"
PASS=0; FAIL=0
check() { [[ "$2" == "$3" ]] && { echo "  PASS  $1"; PASS=$((PASS+1)); } || { echo "  FAIL  $1: expected $2, got $3"; FAIL=$((FAIL+1)); }; }

# Pull the function out with its helpers rather than running the whole CLI.
probe() {
  local f; f="$(mktemp)"
  printf '%s\n' "$@" > "$f"
  bash -c '
    source "'"$SRC"'/scripts/lib/common.sh" >/dev/null 2>&1
    not_enrolled() { printf "NOT-ENROLLED"; exit 0; }
    '"$(sed -n '/^instance_platform_url() {/,/^}/p' "$SRC/scripts/caytu-client")"'
    instance_platform_url "'"$f"'"
  '
  rm -f "$f"
}

echo
echo "which platform the agent talks to"
check "enrolled platform beats the production template" \
  "https://staging.caytu.link" \
  "$(probe "CAYTU_BILLINGS_URL=https://caytu.link" "CAYTU_PLATFORM_URL=https://staging.caytu.link" "PLATFORM_HOST_URL=")"
check "an explicit operator setting still wins" \
  "https://my.host" \
  "$(probe "PLATFORM_HOST_URL=https://my.host" "CAYTU_PLATFORM_URL=https://staging.caytu.link")"
check "falls back to the template when nothing was enrolled" \
  "https://caytu.link" \
  "$(probe "CAYTU_BILLINGS_URL=https://caytu.link")"
check "trailing slash trimmed" \
  "https://staging.caytu.link" \
  "$(probe "CAYTU_PLATFORM_URL=https://staging.caytu.link/")"
check "says so when there is nothing at all" \
  "NOT-ENROLLED" "$(probe "SOMETHING=else")"
echo
printf '  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
