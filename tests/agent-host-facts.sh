#!/usr/bin/env bash
# What the agent tells the platform about the machine it runs on.
#
# The console shows that address as the deployment's own, and builds the
# administrator's invite link from it, so a wrong one is not cosmetic: it points
# people at a host that never answers.
set -uo pipefail
cd "$(dirname "$0")/.."
P=0; F=0
ok()  { echo "  PASS  $1"; P=$((P+1)); }
bad() { echo "  FAIL  $1"; F=$((F+1)); }

AGENT=compose/docker-compose.agent.yml

echo
echo "the agent answers for the host, not for its own container"
python3 - "$AGENT" <<'PY' && ok "it shares the host's network and hostname" || bad "it shares the host's network and hostname"
import sys, yaml
svc = yaml.safe_load(open(sys.argv[1]))["services"]["provisioner-agent"]
sys.exit(0 if svc.get("network_mode") == "host" and svc.get("uts") == "host" else 1)
PY

# Passed in at start, it is whatever the host had that minute. A DHCP lease
# moving afterwards left the console showing an address nothing answered on,
# next to a heartbeat from seconds earlier.
grep -q 'CAYTU_HOST_IP="$host_ip"' scripts/caytu-client \
  && bad "the address is baked into the container at start" \
  || ok "the address is not baked in at start"

# Still settable by hand, for a host whose outbound route is not the address
# clients reach it on.
grep -q 'CAYTU_HOST_IP:-' "$AGENT" \
  && ok "an operator can still override it" || bad "an operator can still override it"
grep -q '\[\[ -n "${CAYTU_HOST_IP:-}" \]\]' scripts/caytu-client \
  && ok "and the override wins over detection" || bad "and the override wins over detection"

bash -n scripts/caytu-client 2>/dev/null && ok "the cli still parses" || bad "the cli still parses"

printf '\n  %d passed, %d failed\n\n' "$P" "$F"
[ "$F" -eq 0 ]
