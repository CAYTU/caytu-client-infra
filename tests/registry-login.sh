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

has "CAYTU_DOCKER_CONFIG=/home/" "the agent is pointed at the deploy user's docker config"
hasnt 'CAYTU_DOCKER_CONFIG=/home/ubuntu/.docker"' "and not at a home that may not exist"
has "registry-credentials" "it can ask the platform for a password"

bash -n scripts/bootstrap.sh 2>/dev/null && ok "bootstrap still parses" || bad "bootstrap still parses"

printf '\n  %d passed, %d failed\n\n' "$P" "$F"
[ "$F" -eq 0 ]
