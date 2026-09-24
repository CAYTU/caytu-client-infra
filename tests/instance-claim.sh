#!/usr/bin/env bash
# Which deployment a host takes off the platform.
#
# One host runs one deployment. Every agent in an organization used to take the
# first one waiting, so a second machine enrolled for a second site never got
# it: the first host was already polling and had it within thirty seconds.
set -uo pipefail
cd "$(dirname "$0")/.."
P=0; F=0
ok()  { echo "  PASS  $1"; P=$((P+1)); }
bad() { echo "  FAIL  $1"; F=$((F+1)); }

# The rule itself, without the loop around it.
eval "$(sed -n '/^claimable_instance()/,/^}/p' scripts/caytu-client)"

waiting() { printf '{"instances":[%s]}' "$1"; }
MINE='{"id":"i-mine","status":"provisioning","provisioningPercent":0,"hostId":"H1"}'
THEIRS='{"id":"i-theirs","status":"provisioning","provisioningPercent":0,"hostId":"H2"}'
NOBODY='{"id":"i-free","status":"provisioning","provisioningPercent":0}'
CLAIMED='{"id":"i-busy","status":"provisioning","provisioningPercent":40}'

echo
echo "a host takes the deployment it was given"
[ "$(claimable_instance "$(waiting "$THEIRS,$MINE")" H1 "")" = "i-mine" ] \
  && ok "its own, even when another host's comes first" || bad "took the wrong one"
[ -z "$(claimable_instance "$(waiting "$THEIRS")" H1 "")" ] \
  && ok "and never one named for another host" || bad "took another host's deployment"

echo
echo "a deployment naming nobody"
[ "$(claimable_instance "$(waiting "$NOBODY")" H1 "")" = "i-free" ] \
  && ok "goes to a host that runs nothing yet" || bad "nobody took an unassigned deployment"
[ -z "$(claimable_instance "$(waiting "$NOBODY")" H1 "i-existing")" ] \
  && ok "and is left alone by a host that already runs one" || bad "a busy host took a second"
# The machine enrolled before deployments named their host.
[ "$(claimable_instance "$(waiting "$NOBODY")" "" "")" = "i-free" ] \
  && ok "a host with no id of its own still provisions" || bad "an older host now takes nothing"

echo
echo "anything already under way"
[ -z "$(claimable_instance "$(waiting "$CLAIMED")" H1 "")" ] \
  && ok "is left to whoever claimed it" || bad "grabbed a deployment in progress"
[ -z "$(claimable_instance '{"instances":[]}' H1 "")" ] \
  && ok "and an empty list takes nothing" || bad "invented a deployment"

printf '\n  %d passed, %d failed\n\n' "$P" "$F"
[ "$F" -eq 0 ]
