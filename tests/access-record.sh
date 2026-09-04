#!/usr/bin/env bash
# What provisioning reads off an instance record and writes onto the host.
#
# The values here decide whether the browser can reach the API at all, and they
# were written for Caytu-hosted deployments only, so every on-premise site got
# an empty API base and a login form that failed silently.
set -uo pipefail
SRC="$(dirname "$(dirname "$(readlink -f "$0")")")"
PASS=0; FAIL=0
check() { [[ "$2" == "$3" ]] && { echo "  PASS  $1"; PASS=$((PASS+1)); } || { echo "  FAIL  $1: expected '$2', got '$3'"; FAIL=$((FAIL+1)); }; }

d="$(mktemp -d)"
export COMPOSE_DIR="$d"
source "$SRC/scripts/lib/common.sh" >/dev/null 2>&1
eval "$(sed -n '/^primary_ip() {/,/^}/p' "$SRC/scripts/caytu-client")"
eval "$(sed -n '/^deployment_scheme() {/,/^}/p' "$SRC/scripts/caytu-client")"
eval "$(sed -n '/^api_base_for() {/,/^}/p' "$SRC/scripts/caytu-client")"
eval "$(sed -n '/^access_scheme() {/,/^}/p' "$SRC/scripts/caytu-client")"
eval "$(sed -n '/^apply_instance_access() {/,/^}/p' "$SRC/scripts/caytu-client")"
eval "$(sed -n '/^instance_hostname() {/,/^}/p' "$SRC/scripts/caytu-client")"

echo
echo "the access record, applied to the host"

# --- which name the deployment answers on -----------------------------------

managed='{"placement":"managed","subdomain":"binseven"}'
check "hosting we run derives its own name" \
  "binseven.caytu.link" "$(instance_hostname "$managed" managed binseven)"

onprem='{"placement":"self-hosted","access":{"resolution":"customer-dns","hostname":"caytu.acme.internal"}}'
check "on-premise takes the name the record carries" \
  "caytu.acme.internal" "$(instance_hostname "$onprem" self-hosted binseven)"

# The bug this replaces: the subdomain was written for every placement, so a
# customer machine advertised a caytu.link name that resolves nowhere.
check "on-premise never gets a caytu.link name" \
  "" "$(instance_hostname "$onprem" self-hosted binseven | grep -o 'caytu.link' || true)"

# The one case where the machine is the only thing that knows its own address.
byip='{"placement":"self-hosted","access":{"resolution":"ip"}}'
check "a site reached by address uses this machine's own" \
  "$(primary_ip)" "$(instance_hostname "$byip" self-hosted binseven)"

nothing='{"placement":"self-hosted","access":{"resolution":"customer-dns"}}'
check "empty when nobody has said, rather than a guess" \
  "" "$(instance_hostname "$nothing" self-hosted binseven)"

# --- http or https ----------------------------------------------------------

check "no certificate means http" "http" "$(deployment_scheme host.acme.internal letsencrypt-http bundled-nginx)"

mkdir -p "$d/certbot/conf/live/host.acme.internal"
touch "$d/certbot/conf/live/host.acme.internal/fullchain.pem"
check "a certificate we hold means https" \
  "https" "$(deployment_scheme host.acme.internal byo bundled-nginx)"

# A site that chose plain HTTP has no certificate by design, so the file test
# would keep it on http forever, which is right, but say so from the record.
check "plain http is a choice, not a missing certificate" \
  "http" "$(deployment_scheme host.acme.internal none bundled-nginx)"

# Nothing lands in our cert dir when something in front terminates TLS, so the
# file test alone would tell the browser to use http and get mixed content.
check "an external proxy terminates it, so https" \
  "https" "$(deployment_scheme lan.acme.internal byo external-proxy)"
check "IIS terminates it too" \
  "https" "$(deployment_scheme lan.acme.internal byo iis)"
check "an external proxy on plain http is still http" \
  "http" "$(deployment_scheme lan.acme.internal none external-proxy)"

# --- the api base, which is the origin and nothing more ---------------------

check "the api base follows the record's scheme" \
  "https://lan.acme.internal" "$(api_base_for lan.acme.internal https)"
check "and still never carries /api" \
  "" "$(api_base_for lan.acme.internal https | grep -o '/api$' || true)"
check "a bare address is a fine api base" \
  "http://10.0.1.42" "$(api_base_for 10.0.1.42 http)"

# --- what lands in the env file ---------------------------------------------

env_file="$d/.env.onprem"
: > "$env_file"
full='{"placement":"self-hosted","access":{"resolution":"customer-dns","tls":"letsencrypt-dns","edge":"bundled-nginx","hostPlatform":"linux-docker","dnsProvider":"cloudflare","acmeEmail":"ops@acme.example"}}'
apply_instance_access "$env_file" "$full"

check "the placement is written" "self-hosted" "$(env_get "$env_file" CAYTU_PLACEMENT)"
check "resolution is written" "customer-dns" "$(env_get "$env_file" CAYTU_ACCESS_RESOLUTION)"
check "tls is written"        "letsencrypt-dns" "$(env_get "$env_file" CAYTU_ACCESS_TLS)"
check "edge is written"       "bundled-nginx" "$(env_get "$env_file" CAYTU_ACCESS_EDGE)"
check "host platform is written" "linux-docker" "$(env_get "$env_file" CAYTU_ACCESS_HOST_PLATFORM)"
check "the dns provider is written" "cloudflare" "$(env_get "$env_file" CAYTU_ACCESS_DNS_PROVIDER)"
# Feeds the variable the certificate step already reads, rather than a second
# one beside it that nothing would consult.
check "the contact address feeds the existing variable" \
  "ops@acme.example" "$(env_get "$env_file" CAYTU_LETSENCRYPT_EMAIL)"

# The frontend builds every public URL from these, so a record that chose a
# certificate and an env file still saying http is the mixed scheme that broke
# login through a CORS preflight redirect.
check "a record with TLS sets the scheme to match" \
  "https" "$(env_get "$env_file" CAYTU_SCHEME)"
check "and the websocket scheme with it" \
  "wss" "$(env_get "$env_file" CAYTU_WS_SCHEME)"

: > "$d/.env.plain"
apply_instance_access "$d/.env.plain" \
  '{"placement":"self-hosted","access":{"resolution":"ip","tls":"none","edge":"bundled-nginx","hostPlatform":"linux-docker"}}'
check "a record with no TLS says http" \
  "http" "$(env_get "$d/.env.plain" CAYTU_SCHEME)"
check "and ws" "ws" "$(env_get "$d/.env.plain" CAYTU_WS_SCHEME)"

check "the scheme comes back out of the env file" \
  "https" "$(printf 'CAYTU_ACCESS_TLS=byo\nCAYTU_ACCESS_EDGE=external-proxy\n' > "$d/.env.x"; access_scheme "$d/.env.x" lan.acme.internal)"

# A record that says nothing writes nothing, so a half-configured instance
# cannot overwrite what an operator set on the box.
: > "$d/.env.empty"
apply_instance_access "$d/.env.empty" '{}'
check "an empty record writes nothing" "" "$(cat "$d/.env.empty")"

rm -rf "$d"
echo
printf '  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
