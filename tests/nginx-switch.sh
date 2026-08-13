#!/usr/bin/env bash
# Switching between plain HTTP and TLS must not lose the proxy rules, which
# live only in default.conf.
set -uo pipefail
SRC="$(dirname "$(dirname "$(readlink -f "$0")")")"
PASS=0; FAIL=0
check() { [[ "$2" == "$3" ]] && { echo "  PASS  $1"; PASS=$((PASS+1)); } || { echo "  FAIL  $1: expected $2, got $3"; FAIL=$((FAIL+1)); }; }

d="$(mktemp -d)"
mkdir -p "$d/nginx/conf.d" "$d/certbot/conf"
cp "$SRC/compose/nginx/conf.d/default.conf" "$d/nginx/conf.d/default.conf"
cp "$SRC/compose/nginx/conf.d/onprem-http.conf.template" "$d/nginx/conf.d/"

COMPOSE_DIR="$d"
source "$SRC/scripts/lib/common.sh" >/dev/null 2>&1
eval "$(sed -n '/^_nginx_tls_conf()/,/^}/p;/^_nginx_conf()/,/^}/p' "$SRC/scripts/caytu-client")"
eval "$(sed -n '/^_ssl_pin_nginx_local()/,/^}/p' "$SRC/scripts/caytu-client")"
eval "$(sed -n '/^_nginx_use_http_only()/,/^}/p' "$SRC/scripts/caytu-client")"
eval "$(sed -n '/^_nginx_use_tls()/,/^}/p' "$SRC/scripts/caytu-client")"

conf="$d/nginx/conf.d/default.conf"
echo
echo "switching nginx between http and tls"
_nginx_use_http_only
check "serves plain http" 1 "$(grep -c 'listen 80 default_server' "$conf")"
check "answers the acme challenge" 1 "$(grep -c 'acme-challenge' "$conf")"
check "the tls config is kept" 1 "$([[ -f "$d/nginx/conf.d/default.conf.tls" ]] && echo 1 || echo 0)"

_nginx_use_tls "binsix.caytu.link"
check "serves tls again" 1 "$(grep -c 'listen 443 ssl' "$conf")"
check "pinned to the real host" 1 "$(grep -c 'server_name binsix.caytu.link;' "$conf")"
check "certificate path pinned" 1 "$(grep -c 'live/binsix.caytu.link/fullchain.pem' "$conf")"
check "placeholder is gone" 0 "$(grep -c 'yourdomain.com' "$conf")"

# The round trip is what matters: an operator may flip back and forth.
_nginx_use_http_only
_nginx_use_tls "binsix.caytu.link"
# One line, and without it the login page silently fails: the browser is told
# where the API is by the frontend, on a path under /api/.
check "tls config sends the config route to the frontend" 1 \
  "$(grep -c 'location = /api/config' "$conf")"
_nginx_use_http_only
check "http-only config does too" 1 "$(grep -c 'location = /api/config' "$conf")"
_nginx_use_tls "binsix.caytu.link"

check "survives a round trip" 1 "$(grep -c 'live/binsix.caytu.link/fullchain.pem' "$conf")"
rm -rf "$d"
echo
printf '  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
