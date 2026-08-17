#!/usr/bin/env bash
# On-premise cannot present an EC2 identity document, so it enrols with a code
# from the console instead. That is a second path to the same state, and the
# only thing keeping the two in step is this.
#
# The hosted path learned several of these the hard way. A machine that enrols
# fine and then reports to the wrong platform looks completely healthy: the 404
# is silent, the admin account is never announced, and the console waits
# forever.
set -uo pipefail
D="$(dirname "$(readlink -f "$0")")"
SRC="$(dirname "$D")"
PASS=0; FAIL=0
check() { [[ "$2" == "$3" ]] && { echo "  PASS  $1"; PASS=$((PASS+1)); } || { echo "  FAIL  $1: expected '$2', got '$3'"; FAIL=$((FAIL+1)); }; }

W="${TMPDIR:-/tmp}/caytu-parity-test"
rm -rf "$W"; mkdir -p "$W"

start_fake() { # port
  python3 "$D/fake-platform.py" "$1" "200" "$W/n.txt" >/dev/null 2>&1 & echo $!
  for _ in $(seq 40); do
    curl -sf -m 1 "http://127.0.0.1:$1/latest/dynamic/instance-identity/document" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
}

# A sandbox in the state an operator is actually in: `init` has copied
# .env.example, which names production, and nothing else has been touched.
sandbox() { # name
  local s="$W/$1"
  rm -rf "$s"; mkdir -p "$s/compose"
  cp -r "$SRC/scripts" "$s/scripts"
  cp "$SRC/compose/.env.example" "$s/compose/.env.onprem"
  chmod 600 "$s/compose/.env.onprem"
  printf '%s' "$s"
}

val() { grep -oP "(?<=^$2=).*" "$1/compose/.env.onprem" 2>/dev/null | head -1; }

port=18091
pid=$(start_fake "$port")
platform="http://127.0.0.1:$port"

hosted="$(sandbox hosted)"
( cd "$hosted" && CAYTU_IMDS_URL="$platform" CAYTU_PLATFORM_URL="$platform" \
    CAYTU_INSTANCE_ID=6a7d802c12e201c214b61aeb \
    bash scripts/caytu-client --target onprem enroll-self ) >"$W/hosted.out" 2>&1

onprem="$(sandbox onprem)"
( cd "$onprem" && bash scripts/caytu-client --target onprem enroll ENROL-CODE \
    --platform "$platform" ) >"$W/onprem.out" 2>&1
kill "$pid" 2>/dev/null

echo
echo "the code flow reaches the same state as the identity flow"

# The credential itself, which is the point of both.
check "the identity flow stores a token" "tok-abc" "$(val "$hosted" CAYTU_METERING_TOKEN)"
check "the code flow stores one too"     "tok-abc" "$(val "$onprem" CAYTU_METERING_TOKEN)"
check "both record the organization" \
  "$(val "$hosted" CAYTU_ORGANIZATION_ID)" "$(val "$onprem" CAYTU_ORGANIZATION_ID)"
# The host renews its own credential, so it has to know when.
check "both record when the credential expires" \
  "$(val "$hosted" CAYTU_TOKEN_EXPIRES_AT)" "$(val "$onprem" CAYTU_TOKEN_EXPIRES_AT)"

# The one that fails silently. .env.example ships this pointing at production,
# so anything that only fills it when empty leaves a site reporting to the
# wrong platform, which answers 404 and tells nobody.
check "the identity flow reports where it enrolled" "$platform" "$(val "$hosted" CAYTU_BILLINGS_URL)"
check "so does the code flow" "$platform" "$(val "$onprem" CAYTU_BILLINGS_URL)"

# Whatever the flow, this is the file the agent later reads to find the
# platform, so both have to leave an answer in it.
check "the identity flow leaves a platform address" 1 \
  "$([[ -n "$(val "$hosted" CAYTU_PLATFORM_URL)$(val "$hosted" PLATFORM_HOST_URL)" ]] && echo 1 || echo 0)"
check "the code flow leaves one" 1 \
  "$([[ -n "$(val "$onprem" CAYTU_PLATFORM_URL)$(val "$onprem" PLATFORM_HOST_URL)" ]] && echo 1 || echo 0)"

# A copy of this file is a working credential for the organization.
check "the identity flow leaves it owner-only" "600" "$(stat -c '%a' "$hosted/compose/.env.onprem")"
check "the code flow does too"                 "600" "$(stat -c '%a' "$onprem/compose/.env.onprem")"

# Nothing is left pointing at the template's production default anywhere the
# deployment reads a platform from.
for v in CAYTU_BILLINGS_URL CAYTU_PLATFORM_URL PLATFORM_HOST_URL; do
  got="$(val "$onprem" "$v")"
  check "the code flow leaves no stale caytu.link in $v" "" \
    "$(printf '%s' "$got" | grep -o 'https://caytu.link' || true)"
done

# The exception, and the reason this was conditional in the first place: on a
# developer's machine these are docker service names, and a host address points
# the running stack at a port it cannot see.
port=18092
pid=$(start_fake "$port")
dev="$(sandbox dev)"
mkdir -p "$dev/compose"
printf 'CAYTU_BILLINGS_URL=http://billings-srv:3000\nCAYTU_PLATFORM_URL=http://billings-srv:3000\n' \
  > "$dev/compose/.env.local"
( cd "$dev" && bash scripts/caytu-client --target local enroll ENROL-CODE \
    --platform "http://127.0.0.1:$port" ) >"$W/dev.out" 2>&1
kill "$pid" 2>/dev/null
check "a local stack keeps its service names" "http://billings-srv:3000" \
  "$(grep -oP '(?<=^CAYTU_BILLINGS_URL=).*' "$dev/compose/.env.local" | head -1)"
check "and still gets its credential" "tok-abc" \
  "$(grep -oP '(?<=^CAYTU_METERING_TOKEN=).*' "$dev/compose/.env.local" | head -1)"

rm -rf "$W"
echo
printf '  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
