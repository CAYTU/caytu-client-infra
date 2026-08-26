#!/usr/bin/env bash
# Logging in to the registry when the host has no AWS identity.
set -uo pipefail
cd "$(dirname "$0")/.."

P=0; F=0
ok()   { echo "  PASS  $1"; P=$((P+1)); }
bad()  { echo "  FAIL  $1: $2"; F=$((F+1)); }
check() { [[ "$2" == *"$1"* ]] && ok "$3" || bad "$3" "got '$2'"; }

eval "$(sed -n '/^registry_login_via_platform()/,/^}/p' scripts/caytu-client)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
env_file="$TMP/.env"

env_get() { grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2- || true; }
instance_platform_url() { echo "https://platform.test"; }

# Stand in for the network and for docker, recording what each was asked.
curl() { cat "$TMP/response" 2>/dev/null || return 1; }
docker() { cat > "$TMP/password-stdin"; printf '%s\n' "$*" > "$TMP/docker-args"; }

printf 'CAYTU_METERING_TOKEN=ct_test\n' > "$env_file"

echo "the platform issues one"
printf '{"registry":"688544396352.dkr.ecr.us-east-1.amazonaws.com","username":"AWS","password":"secret-token","expiresAt":"2026-01-01T00:00:00Z"}' > "$TMP/response"
if registry_login_via_platform "$env_file" "guessed.registry"; then ok "login succeeds"; else bad "login succeeds" "returned non-zero"; fi
check "secret-token" "$(cat "$TMP/password-stdin")" "the password goes in over stdin, not the command line"
check "688544396352.dkr.ecr.us-east-1.amazonaws.com" "$(cat "$TMP/docker-args")" "the platform's registry wins over the guess"
check "AWS" "$(cat "$TMP/docker-args")" "the username is used"

echo
echo "there is nothing to authenticate with"
printf 'OTHER=1\n' > "$env_file"
if registry_login_via_platform "$env_file" "r"; then bad "refuses without a token" "returned zero"; else ok "refuses without a token"; fi

echo
echo "the platform answers but not with credentials"
printf 'CAYTU_METERING_TOKEN=ct_test\n' > "$env_file"
printf '{"message":"nope"}' > "$TMP/response"
if registry_login_via_platform "$env_file" "r"; then bad "refuses an answer with no password" "returned zero"; else ok "refuses an answer with no password"; fi

echo
printf '  %d passed, %d failed\n' "$P" "$F"
[[ "$F" -eq 0 ]]
