#!/usr/bin/env bash
# What the certificate step does with each value the record can carry, and what
# it refuses to install.
#
# Every mode used to attempt HTTP-01, so a site that brought its own certificate
# waited five minutes for a challenge it never wanted. And a mismatched pair
# went straight to nginx, which refuses to start on one, taking the site down
# somewhere far from where it was typed.
set -uo pipefail
SRC="$(dirname "$(dirname "$(readlink -f "$0")")")"
PASS=0; FAIL=0
check() { [[ "$2" == "$3" ]] && { echo "  PASS  $1"; PASS=$((PASS+1)); } || { echo "  FAIL  $1: expected '$2', got '$3'"; FAIL=$((FAIL+1)); }; }

d="$(mktemp -d)"
export COMPOSE_DIR="$d" TARGET=onprem
mkdir -p "$d/nginx/conf.d" "$d/certbot/conf"
cp "$SRC/compose/nginx/conf.d/default.conf" "$d/nginx/conf.d/default.conf"
cp "$SRC/compose/nginx/conf.d/onprem-http.conf.template" "$d/nginx/conf.d/"

source "$SRC/scripts/lib/common.sh" >/dev/null 2>&1

# Some of these are written on one line, where a /^}/ range never terminates and
# quietly yields nothing. A helper that came back undefined took three failing
# assertions to notice, so match that shape first.
load_fn() {
  local fn=$1 line
  line="$(grep -m1 -E "^${fn}\(\)[[:space:]]*\{.*\}[[:space:]]*$" "$SRC/scripts/caytu-client" || true)"
  [[ -n "$line" ]] && { eval "$line"; return; }
  eval "$(sed -n "/^${fn}() {/,/^}/p" "$SRC/scripts/caytu-client")"
  declare -F "$fn" >/dev/null || { echo "  FAIL  could not load $fn"; exit 1; }
}
for fn in _ssl_cert_dir_local _ssl_pin_nginx_local _nginx_tls_conf _nginx_conf \
          _nginx_use_http_only _nginx_use_tls cert_self_signed cert_pair_ok \
          cert_covers_host cert_days_left cert_mode_for issue_certificate \
          prepare_nginx; do
  load_fn "$fn"
done
# The stack is not running here, so these must not reach docker.
compose() { :; }
require_cmd() { :; }

echo
echo "certificates, by what the record says"

env_file="$d/.env.onprem"
mode() { printf 'CAYTU_ACCESS_TLS=%s\nCAYTU_ACCESS_EDGE=%s\n' "$1" "${2:-bundled-nginx}" > "$env_file"; }

# --- which mode is chosen ----------------------------------------------------

: > "$env_file"
check "hosting we run still defaults to http-01" \
  "letsencrypt-http" "$(cert_mode_for "$env_file")"
mode byo
check "the record's mode wins" "byo" "$(cert_mode_for "$env_file")"

# A record written before the platform recorded access at all. Defaulting these
# to http-01 is what sent a LAN box to wait on a challenge it could never get.
printf 'CAYTU_PLACEMENT=self-hosted\n' > "$env_file"
check "an on-premise host with no record falls back to self-signed" \
  "self-signed" "$(cert_mode_for "$env_file")"
printf 'CAYTU_PLACEMENT=managed\n' > "$env_file"
check "and hosting we run still falls back to http-01" \
  "letsencrypt-http" "$(cert_mode_for "$env_file")"
printf 'CAYTU_PLACEMENT=self-hosted\nCAYTU_ACCESS_TLS=byo\n' > "$env_file"
check "an explicit choice still beats the fallback" "byo" "$(cert_mode_for "$env_file")"

# --- the modes that must not call out ----------------------------------------

# Each of these would otherwise spend ACME_WAIT_TRIES * ACME_WAIT_SECONDS
# waiting for a challenge that was never going to be served.
mode byo
issue_certificate "$env_file" "https://lan.acme.internal" >/dev/null 2>&1
check "bring-your-own asks nobody and installs nothing" \
  1 "$([[ ! -f "$d/certbot/conf/live/lan.acme.internal/fullchain.pem" ]] && echo 1 || echo 0)"

mode none
issue_certificate "$env_file" "https://lan.acme.internal" >/dev/null 2>&1
check "plain http by choice issues nothing" "1" \
  "$([[ ! -f "$d/certbot/conf/live/lan.acme.internal/fullchain.pem" ]] && echo 1 || echo 0)"

mode letsencrypt-dns
issue_certificate "$env_file" "https://lan.acme.internal" >/dev/null 2>&1
check "dns-01 says so rather than burning a rate limit" "1" \
  "$([[ ! -f "$d/certbot/conf/live/lan.acme.internal/fullchain.pem" ]] && echo 1 || echo 0)"

# An external edge holds the certificate; ours would never be presented.
mode letsencrypt-http external-proxy
issue_certificate "$env_file" "https://lan.acme.internal" >/dev/null 2>&1
check "an external edge means we issue nothing" "1" \
  "$([[ ! -f "$d/certbot/conf/live/lan.acme.internal/fullchain.pem" ]] && echo 1 || echo 0)"

# --- self-signed, which is the one we can do offline -------------------------

mode self-signed
issue_certificate "$env_file" "https://lan.acme.internal" >/dev/null 2>&1
check "self-signed produces a certificate" "1" \
  "$([[ -f "$d/certbot/conf/live/lan.acme.internal/fullchain.pem" ]] && echo 1 || echo 0)"
check "and serves it" 1 "$(grep -c 'server_name lan.acme.internal;' "$d/nginx/conf.d/default.conf")"
check "the key is not world readable" "600" \
  "$(stat -c '%a' "$d/certbot/conf/live/lan.acme.internal/privkey.pem")"

# A bare address is exactly the case no public CA will serve, so the SAN has to
# carry it as an IP or browsers reject it however valid the certificate is.
cert_self_signed 10.0.1.42 >/dev/null 2>&1
check "a bare address gets an IP SAN" 1 \
  "$(openssl x509 -noout -text -in "$d/certbot/conf/live/10.0.1.42/fullchain.pem" \
     | grep -c 'IP Address:10.0.1.42')"

# --- what bring-your-own refuses ---------------------------------------------

echo
echo "what bring-your-own refuses"

mk() { # name, CN, san
  openssl req -x509 -nodes -newkey rsa:2048 -keyout "$d/$1.key" -out "$d/$1.crt" \
    -days 30 -subj "/CN=$2" -addext "subjectAltName=$3" 2>/dev/null
}
mk good caytu.acme.internal "DNS:caytu.acme.internal"
mk other elsewhere.example  "DNS:elsewhere.example"
mk wild  '*.acme.internal'  "DNS:*.acme.internal"

check "a matching pair is accepted" 0 \
  "$(cert_pair_ok "$d/good.crt" "$d/good.key" caytu.acme.internal >/dev/null 2>&1; echo $?)"

# The one that takes the site down: nginx will not start on it.
check "a key from another certificate is refused" 1 \
  "$(cert_pair_ok "$d/good.crt" "$d/other.key" caytu.acme.internal >/dev/null 2>&1; echo $?)"

# An already-expired certificate, which openssl only backdates through `ca`.
mkdir -p "$d/ca"; : > "$d/ca/index.txt"; echo 01 > "$d/ca/serial"
cat > "$d/ca/openssl.cnf" <<EOF
[ca]
default_ca = d
[d]
dir = $d/ca
database = \$dir/index.txt
serial = \$dir/serial
new_certs_dir = \$dir
default_md = sha256
policy = any
[any]
commonName = optional
EOF
openssl req -x509 -nodes -newkey rsa:2048 -keyout "$d/ca/ca.key" -out "$d/ca/ca.crt" \
  -days 365 -subj "/CN=test ca" 2>/dev/null
openssl req -new -nodes -newkey rsa:2048 -keyout "$d/old.key" -out "$d/old.csr" \
  -subj "/CN=caytu.acme.internal" 2>/dev/null
openssl ca -batch -config "$d/ca/openssl.cnf" -keyfile "$d/ca/ca.key" -cert "$d/ca/ca.crt" \
  -startdate "$(date -u -d '3 days ago' +%y%m%d%H%M%SZ)" \
  -enddate   "$(date -u -d '2 days ago' +%y%m%d%H%M%SZ)" \
  -in "$d/old.csr" -out "$d/old.crt" 2>/dev/null
check "the expired fixture was built" 1 \
  "$(openssl x509 -checkend 0 -noout -in "$d/old.crt" >/dev/null 2>&1 && echo 0 || echo 1)"
check "an expired certificate is refused" 1 \
  "$(cert_pair_ok "$d/old.crt" "$d/old.key" caytu.acme.internal >/dev/null 2>&1; echo $?)"

# A wrong name is the operator's call, not ours: wildcards and SAN lists we read
# badly are both plausible, so it warns and installs.
check "a name that does not match warns but installs" 0 \
  "$(cert_pair_ok "$d/other.crt" "$d/other.key" caytu.acme.internal >/dev/null 2>&1; echo $?)"

check "the host is found in the SANs" 0 \
  "$(cert_covers_host "$d/good.crt" caytu.acme.internal; echo $?)"
check "a different host is not" 1 \
  "$(cert_covers_host "$d/good.crt" other.acme.internal; echo $?)"
check "a wildcard covers one label" 0 \
  "$(cert_covers_host "$d/wild.crt" caytu.acme.internal; echo $?)"
check "and not two" 1 \
  "$(cert_covers_host "$d/wild.crt" a.b.acme.internal; echo $?)"

check "days remaining is read" 1 \
  "$(days="$(cert_days_left "$d/good.crt")"; [[ "$days" -ge 28 && "$days" -le 30 ]] && echo 1 || echo 0)"
check "an expired one reads negative" 1 \
  "$(days="$(cert_days_left "$d/old.crt")"; [[ "$days" -lt 0 ]] && echo 1 || echo 0)"

# --- nginx, before it starts -------------------------------------------------

echo
echo "where nginx listens"

rm -rf "$d/certbot/conf/live"
mode byo external-proxy
prepare_nginx "$env_file" "https://lan.acme.internal" >/dev/null 2>&1
# Both want :80. Leaving nginx on it is the collision the access-modes doc
# warns about, and it fails as a port bind rather than as anything readable.
check "an external edge pushes nginx to loopback" \
  "127.0.0.1:8080" "$(env_get "$env_file" NGINX_HTTP_BIND)"
check "including https" "127.0.0.1:8443" "$(env_get "$env_file" NGINX_HTTPS_BIND)"
check "and serves plain http inside, since they terminate" 1 \
  "$(grep -c 'listen 80 default_server' "$d/nginx/conf.d/default.conf")"
# The trap that is not obvious: a customer proxy sending all of /api/ to the
# backend breaks the login page. Ours keeps the exception, so theirs never
# needs to know.
check "the config route still goes to the frontend" 1 \
  "$(grep -c 'location = /api/config' "$d/nginx/conf.d/default.conf")"

mode letsencrypt-http bundled-nginx
prepare_nginx "$env_file" "https://lan.acme.internal" >/dev/null 2>&1
check "we keep the real ports when we are the edge" 1 \
  "$(grep -c 'listen 80 default_server' "$d/nginx/conf.d/default.conf")"

rm -rf "$d"
echo
printf '  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
