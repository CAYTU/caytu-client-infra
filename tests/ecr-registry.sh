#!/usr/bin/env bash
# Which registry a machine pulls from. It is read from instance metadata, not
# the AWS CLI, because the agent runs in a container that has none.
set -uo pipefail
D="$(dirname "$(readlink -f "$0")")"
SRC="$(dirname "$D")"
PASS=0; FAIL=0
check() { [[ "$2" == "$3" ]] && { echo "  PASS  $1"; PASS=$((PASS+1)); } || { echo "  FAIL  $1: expected '$2', got '$3'"; FAIL=$((FAIL+1)); }; }

port=18091
python3 "$D/fake-platform.py" "$port" 200 "$(mktemp)" >/dev/null 2>&1 &
fake=$!
for _ in $(seq 40); do
  curl -sf -m 1 "http://127.0.0.1:$port/latest/dynamic/instance-identity/document" >/dev/null 2>&1 && break
  sleep 0.1
done

probe() { # imds-url
  bash -c '
    source "'"$SRC"'/scripts/lib/common.sh" >/dev/null 2>&1
    CAYTU_IMDS_URL="'"$1"'"
    '"$(sed -n '/^imds_get() {/,/^}/p' "$SRC/scripts/caytu-client")"'
    '"$(sed -n '/^ecr_registry_here() {/,/^}/p' "$SRC/scripts/caytu-client")"'
    ecr_registry_here
  '
}

echo
echo "which registry this machine pulls from"
check "built from the machine's own account and region" \
  "688544396352.dkr.ecr.us-east-1.amazonaws.com" "$(probe "http://127.0.0.1:$port")"

# The bug this replaced: a bare name docker reads as a Docker Hub org.
check "never the bare compose default" "" "$(probe "http://127.0.0.1:$port" | grep -o '^caytu-client$' || true)"

# Not an EC2 machine. A customer running our images elsewhere is legitimate,
# so this stays quiet rather than guessing.
check "empty when there is no metadata" "" "$(probe "http://127.0.0.1:1")"

kill "$fake" 2>/dev/null
echo
printf '  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
