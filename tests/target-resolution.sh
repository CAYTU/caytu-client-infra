#!/usr/bin/env bash
# Which env file a command reads when nobody said.
#
# This defaulted to "local". On a customer machine that meant every command
# without -t quietly read the dev env file and talked to localhost, and the
# failure landed nowhere near the cause: enrol wrote .env.onprem, provision read
# .env.local and reported it could not reach the platform.
set -uo pipefail
SRC="$(dirname "$(dirname "$(readlink -f "$0")")")"
PASS=0; FAIL=0
check() { [[ "$2" == "$3" ]] && { echo "  PASS  $1"; PASS=$((PASS+1)); } || { echo "  FAIL  $1: expected '$2', got '$3'"; FAIL=$((FAIL+1)); }; }

sandbox() { # env files to create
  local d; d="$(mktemp -d)"
  mkdir -p "$d/compose"
  cp -r "$SRC/scripts" "$d/scripts"
  cp "$SRC/compose/.env.example" "$d/compose/.env.example"
  local t
  for t in "$@"; do : > "$d/compose/.env.$t"; done
  printf '%s' "$d"
}

run() { # dir, args...
  local d=$1; shift
  (cd "$d" && CAYTU_TARGET= bash scripts/caytu-client "$@" 2>&1)
}

echo
echo "which target a command means"

# A machine nobody has configured yet is about to become an on-premise host.
# Nothing else runs bootstrap.sh.
d="$(sandbox)"
check "a fresh machine assumes on-premise" 1 "$(run "$d" doctor | grep -c 'target: onprem')"
rm -rf "$d"

# The whole point: one target configured is not a question.
d="$(sandbox onprem)"
check "one target is used without being asked" 1 "$(run "$d" doctor | grep -c 'target: onprem')"
rm -rf "$d"

# The bug. Before this, both-configured silently picked local.
d="$(sandbox local onprem)"
out="$(run "$d" instance provision abc123)"
check "several targets are refused, not guessed" 1 "$(printf '%s' "$out" | grep -c 'several targets')"
check "and it never silently picks one" 0 "$(printf '%s' "$out" | grep -c 'target: local')"
# The message has to carry the command back, or you retype it from memory.
check "the fix is spelled out with your own command" 1 \
  "$(printf '%s' "$out" | grep -c 'caytu-client -t local instance provision abc123')"
rm -rf "$d"

# An explicit flag always wins, whatever is on disk.
d="$(sandbox local onprem)"
check "-t still decides" 1 "$(run "$d" -t onprem doctor | grep -c 'target: onprem')"
rm -rf "$d"

# .env.example ships in the repo and is not a configured target.
d="$(sandbox)"
check "the example file is not mistaken for a target" 1 \
  "$(run "$d" doctor | grep -c 'target: onprem')"
rm -rf "$d"

echo
printf '  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
