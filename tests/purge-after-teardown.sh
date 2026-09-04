#!/usr/bin/env bash
# Which deployment a teardown or a purge is allowed to act on.
set -uo pipefail
cd "$(dirname "$0")/.."

P=0; F=0
good() { echo "  PASS  $1"; P=$((P+1)); }
bad()  { echo "  FAIL  $1"; F=$((F+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ENV="$TMP/.env.test"
env_get() { grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-; }
eval "$(sed -n '/^command_targets_current_stack()/,/^}/p' scripts/caytu-client)"

echo "the deployment this host is running"
printf 'CAYTU_INSTANCE_ID=abc123\nCAYTU_KNOWN_INSTANCE_IDS=abc123\n' > "$ENV"
command_targets_current_stack "$ENV" abc123 && good "is acted on" || bad "refused its own stack"
command_targets_current_stack "$ENV" other9 && bad "acted on another deployment" || good "and nobody else's"

echo
echo "after a teardown, which clears the id"
# This is the case that lost every on-premise purge: terminate empties
# CAYTU_INSTANCE_ID, and the destroy arrives seconds later for that same id.
printf 'CAYTU_INSTANCE_ID=\nCAYTU_KNOWN_INSTANCE_IDS=abc123\n' > "$ENV"
command_targets_current_stack "$ENV" abc123 \
  && good "the purge still lands on the stack it was sent to" \
  || bad "skipped the purge, leaving the volumes behind"

# A host that has never run it has nothing of its to remove.
command_targets_current_stack "$ENV" never1 && bad "purged a deployment it never ran" || good "and not one it never ran"

echo
echo "once this host has been given another deployment"
printf 'CAYTU_INSTANCE_ID=def456\nCAYTU_KNOWN_INSTANCE_IDS=abc123 def456\n' > "$ENV"
command_targets_current_stack "$ENV" abc123 \
  && bad "wiped the deployment running now" \
  || good "an old purge is refused, which is what the guard is for"

echo
echo "$P passed, $F failed"
[ "$F" -eq 0 ]
