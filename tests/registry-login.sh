#!/usr/bin/env bash
# A host that is not EC2 still has to log in to the registry, or every pull
# fails with "no basic auth credentials".
set -uo pipefail
cd "$(dirname "$0")/.."
P=0; F=0
ok()  { echo "  PASS  $1"; P=$((P+1)); }
bad() { echo "  FAIL  $1"; F=$((F+1)); }
has()   { grep -q "$1" scripts/bootstrap.sh && ok "$2" || bad "$2"; }
hasnt() { grep -q "$1" scripts/bootstrap.sh && bad "$2" || ok "$2"; }

echo
echo "the registry login reaches a machine that is not EC2"
# The login is for our registry, so whether IMDS answers says nothing about it.
awk '/cat > \/usr\/local\/bin\/caytu-ecr-login/{found=1} END{exit !found}' scripts/bootstrap.sh \
  && ok "the login script is written" || bad "the login script is written"

# It must not sit inside the block that only runs when IMDS answered.
python3 - <<'PY' && ok "and not only when IMDS answers" || bad "and not only when IMDS answers"
import re, sys
s = open("scripts/bootstrap.sh").read()
guard = s.find('if [[ -n "$account" && -n "$region" ]]')
login = s.find("cat > /usr/local/bin/caytu-ecr-login")
sys.exit(0 if guard == -1 or login < guard else 1)
PY

# One directory, or the timer refreshes a login nobody mounts. It named the
# deploy user's home while the timer wrote to /var/lib/caytu-client/.docker, so
# the agent's copy went stale twelve hours after `agent up` primed it.
hasnt 'CAYTU_DOCKER_CONFIG=/home/' "the agent is not pointed at a user's home"
has 'CAYTU_DOCKER_CONFIG=\${docker_cfg' "it is pointed at the directory the timer refreshes"
has "registry-credentials" "it can ask the platform for a password"

echo
echo "the agent can keep its own login fresh"
# An ECR password lasts twelve hours. Read-only, the container could not renew
# it and every pull after that failed until somebody re-ran `agent up` as root.
grep -q ':/root/.docker:ro' compose/docker-compose.agent.yml \
  && bad "the agent's docker config is mounted read-only" \
  || ok "the agent's docker config is writable"

# IMAGE_REGISTRY is written when an instance is picked up, which is after the
# agent starts: a fresh host logged in to nothing and its first pull failed.
python3 - <<'PYCHECK' && ok "agent up primes a login before any instance exists" || bad "agent up primes a login before any instance exists"
import sys
s = open("scripts/caytu-client").read()
start = s.find("cmd_agent()")
if start == -1:
    sys.exit(1)
block = s[start:s.find("\n}\n", start)]
up = block[block.find("    up)"):block.find("    down)")]
sys.exit(0 if "caytu_registry" in up and "ecr_login_if_needed" in up else 1)
PYCHECK

bash -n scripts/bootstrap.sh 2>/dev/null && ok "bootstrap still parses" || bad "bootstrap still parses"

printf '\n  %d passed, %d failed\n\n' "$P" "$F"
[ "$F" -eq 0 ]
