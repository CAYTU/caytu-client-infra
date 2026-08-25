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
  CAYTU_IMAGE_ACCOUNT="${CAYTU_IMAGE_ACCOUNT-}" \
  CAYTU_IMAGE_REGION="${CAYTU_IMAGE_REGION-}" \
  bash -c '
    source "'"$SRC"'/scripts/lib/common.sh" >/dev/null 2>&1
    CAYTU_IMDS_URL="'"$1"'"
    '"$(sed -n '/^imds_get() {/,/^}/p' "$SRC/scripts/caytu-client")"'
    '"$(sed -n '/^caytu_registry() {/,/^}/p' "$SRC/scripts/caytu-client")"'
    caytu_registry
  '
}

echo
echo "which registry a machine pulls from"
check "always ours, whatever machine this is" \
  "688544396352.dkr.ecr.us-east-1.amazonaws.com" "$(probe "http://127.0.0.1:$port")"

# The bug this replaced: derived from the machine's own account, which is right
# only while every machine is in our account. In a customer's it resolved to
# their empty repositories and every pull failed on a manifest never pushed.
check "not the machine's own account" \
  "688544396352.dkr.ecr.us-east-1.amazonaws.com" "$(probe "http://127.0.0.1:1")"

# The other half of that bug: ECR is regional and our images are in one region.
check "not the machine's own region" \
  "688544396352.dkr.ecr.us-east-1.amazonaws.com" \
  "$(CAYTU_IMAGE_REGION= probe "http://127.0.0.1:$port")"

check "a fork or a mirror can be named" \
  "111122223333.dkr.ecr.eu-west-3.amazonaws.com" \
  "$(CAYTU_IMAGE_ACCOUNT=111122223333 CAYTU_IMAGE_REGION=eu-west-3 probe "http://127.0.0.1:$port")"

direct() {
  bash -c '
    source "'"$SRC"'/scripts/lib/common.sh" >/dev/null 2>&1
    CAYTU_IMDS_URL="'"$1"'"
    '"$(sed -n '/^imds_get() {/,/^}/p' "$SRC/scripts/caytu-client")"'
    '"$(sed -n '/^direct_url() {/,/^}/p' "$SRC/scripts/caytu-client")"'
    direct_url
  '
}

echo
echo "the address that works before dns does"
check "built from the machine's public address" \
  "http://203.0.113.7" "$(direct "http://127.0.0.1:$port")"
check "empty off EC2, rather than a guess" "" "$(direct "http://127.0.0.1:1")"

kill "$fake" 2>/dev/null
echo
printf '  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
