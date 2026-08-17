#!/usr/bin/env bash
# Seeding the encrypted secret store at provision time.
#
# An unseeded store is the worst failure this stack has: every container is
# healthy, the console says running, and every route but auth answers 503. So
# the interesting cases are the ones where seeding does not work, and whether
# the deployment says so instead of looking fine.
set -uo pipefail
SRC="$(dirname "$(dirname "$(readlink -f "$0")")")"
PASS=0; FAIL=0
check() { [[ "$2" == "$3" ]] && { echo "  PASS  $1"; PASS=$((PASS+1)); } || { echo "  FAIL  $1: expected '$2', got '$3'"; FAIL=$((FAIL+1)); }; }

d="$(mktemp -d)"
export COMPOSE_DIR="$d" TARGET=onprem
source "$SRC/scripts/lib/common.sh" >/dev/null 2>&1
eval "$(sed -n '/^bootstrap_secret_store() {/,/^}/p' "$SRC/scripts/caytu-client")"

env_file="$d/.env.onprem"

# Stands in for the container run. COMPOSE_RC is what it exits with.
#
# Files, not variables: the calls happen inside $( ), so anything set in the
# stub would be lost with the subshell.
compose() {
  if [[ "$1" == "restart" ]]; then printf '%s' "$*" > "$d/restarted"; return 0; fi
  printf '%s' "$*" > "$d/args"
  printf 'secret store seeded for org-123\n'
  return "${COMPOSE_RC:-0}"
}
args()      { cat "$d/args" 2>/dev/null; }
restarted() { cat "$d/restarted" 2>/dev/null; }
reset()     { rm -f "$d/args" "$d/restarted"; }

echo
echo "seeding the secret store"

printf 'CAYTU_ORGANIZATION_ID=org-123\n' > "$env_file"
reset; export COMPOSE_RC=0
out="$(bootstrap_secret_store "$env_file" 2>&1)"; rc=$?
check "a fresh store is seeded" 0 "$rc"
check "the image is asked to do it, not us" 1 \
  "$(args | grep -c -- '--bootstrap-store')"
# The shard lives in the bundle. Anything that made this host hold one would be
# a step backwards, so the customer id is all that goes in.
check "the customer id is passed in" 1 \
  "$(args | grep -c 'CAYTU_CUSTOMER_ID=org-123')"
check "no shard is handled here" 0 \
  "$(args | grep -ci 'SECRET_STORE_KEY\|RCFG_TAG')"
# It reads the store at boot and will not look again on its own.
check "the backend is restarted so it sees the store" 1 \
  "$(restarted | grep -c 'restart backend')"

# An image built before the flag existed ignores it and starts the server, so
# the run never returns. The timeout is inside the container for that reason,
# and 124 is how it comes back.
printf 'CAYTU_ORGANIZATION_ID=org-123\n' > "$env_file"
check "the timeout runs in the container, not here" 1 \
  "$(reset; COMPOSE_RC=0 bootstrap_secret_store "$env_file" >/dev/null 2>&1; args | grep -c 'backend timeout 120 node')"

reset; export COMPOSE_RC=124
out="$(bootstrap_secret_store "$env_file" 2>&1)"; rc=$?
check "an old image is reported, not retried forever" 1 "$rc"
check "and says what to do about it" 1 "$(printf '%s' "$out" | grep -c 'rebuild it')"
check "a failed seed does not restart the backend" "" "$(restarted)"

export COMPOSE_RC=1
out="$(bootstrap_secret_store "$env_file" 2>&1)"; rc=$?
check "any other failure is reported" 1 "$rc"
check "and names the consequence" 1 "$(printf '%s' "$out" | grep -c 'cannot be licensed')"

# Falls back to the deployment id, so a host that enrolled but has no org
# recorded still gets a store rather than nothing.
printf 'CAYTU_INSTANCE_ID=6a7d802c12e201c214b61aeb\n' > "$env_file"
reset; export COMPOSE_RC=0
bootstrap_secret_store "$env_file" >/dev/null 2>&1
check "the deployment id stands in for the customer" 1 \
  "$(args | grep -c 'CAYTU_CUSTOMER_ID=6a7d802c12e201c214b61aeb')"

: > "$env_file"
out="$(bootstrap_secret_store "$env_file" 2>&1)"; rc=$?
check "no customer id is refused rather than guessed" 1 "$rc"

rm -rf "$d"
echo
printf '  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
