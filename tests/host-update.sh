#!/usr/bin/env bash
# Moving one machine's deployment onto another release.
set -uo pipefail
cd "$(dirname "$0")/.."

P=0; F=0
good() { echo "  PASS  $1"; P=$((P+1)); }
bad() { echo "  FAIL  $1"; F=$((F+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ENV="$TMP/.env.test"

env_get() { grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-; }
env_upsert() {
  local f=$1 k=$2 v=$3
  grep -qE "^$k=" "$f" 2>/dev/null && sed -i "s|^$k=.*|$k=$v|" "$f" || printf '%s=%s\n' "$k" "$v" >> "$f"
}
# command_execute logs through info/ok/warn. Silenced, and `ok` in
# particular, so its "finished" line does not land in the tally below.
info() { :; }; ok() { :; }; warn() { :; }
eval "$(sed -n '/^compose_failure_reason()/,/^}/p' scripts/caytu-client)"
instance_platform_url() { echo "http://platform.test"; }
command_targets_current_stack() { return "$TARGETS_RC"; }
forget_instance() { :; }
MAX_RESULT_BYTES=262144
AGENT_STOP_REASON=""
REPORTED="$TMP/reported"; : > "$REPORTED"
instance_report() { echo "$3" >> "$REPORTED"; }

COMPOSE_LOG="$TMP/compose.log"
PULL_RC=0; UP_RC=0; TARGETS_RC=0
compose() {
  echo "compose $*" >> "$COMPOSE_LOG"
  case "$1" in
    pull) [ "$PULL_RC" -ne 0 ] && { echo "manifest for caytu-client-backend:v9.9.9 not found"; return "$PULL_RC"; } ;;
    up)   [ "$UP_RC" -ne 0 ] && { echo "error: no such image"; return "$UP_RC"; } ;;
  esac
  return 0
}

PAYLOAD="$TMP/payload"
curl() {
  local f
  for f in "$@"; do case "$f" in --data-binary) : ;; @*) cp "${f#@}" "$PAYLOAD" ;; esac; done
  return 0
}

eval "$(sed -n '/^command_execute()/,/^}/p' scripts/caytu-client)"

fresh() {
  printf 'CAYTU_METERING_TOKEN=ct_tok\nCAYTU_INSTANCE_ID=abc123\nIMAGE_TAG=v1.0.0\n' > "$ENV"
  : > "$COMPOSE_LOG"; : > "$REPORTED"; : > "$PAYLOAD"
}
status_of() { jq -r '.status' "$PAYLOAD"; }
error_of()  { jq -r '.error // ""' "$PAYLOAD"; }

echo "an update pins the new version and brings the stack back on it"
fresh
command_execute "$ENV" tok abc123 '{"id":"c1","type":"update","params":{"tag":"v1.2.0"}}'
[ "$(env_get "$ENV" IMAGE_TAG)" = "v1.2.0" ] && good "the version is written" || bad "IMAGE_TAG is $(env_get "$ENV" IMAGE_TAG)"
# Pulled before anything is recreated, so a bad tag cannot stop a working stack.
grep -q "compose pull" "$COMPOSE_LOG" && good "the images are pulled" || bad "never pulled"
[ "$(grep -n 'compose pull' "$COMPOSE_LOG" | cut -d: -f1)" -lt "$(grep -n 'compose up' "$COMPOSE_LOG" | head -1 | cut -d: -f1)" ] \
  && good "pulled before the stack is recreated" || bad "recreated before pulling"
[ "$(status_of)" = "done" ] && good "reported done" || bad "reported $(status_of)"
# The record should say what is running as soon as it is true.
grep -q '"version": *"v1.2.0"' "$REPORTED" && good "the platform is told the version" || bad "no version reported"

echo
echo "a version that cannot be pulled leaves the deployment alone"
fresh
PULL_RC=1
command_execute "$ENV" tok abc123 '{"id":"c2","type":"update","params":{"tag":"v9.9.9"}}'
[ "$(status_of)" = "failed" ] && good "reported failed" || bad "reported $(status_of)"
[ "$(env_get "$ENV" IMAGE_TAG)" = "v1.0.0" ] && good "the old version is put back" || bad "left on $(env_get "$ENV" IMAGE_TAG)"
grep -q "compose up" "$COMPOSE_LOG" && bad "recreated the stack anyway" || good "the running stack is untouched"
# Compose said exactly what was wrong; our own words would have thrown it away.
[[ "$(error_of)" == *"manifest"* ]] && good "carries the registry's reason" || bad "said '$(error_of)'"
PULL_RC=0

echo
echo "a version that will not start is rolled back"
fresh
UP_RC=1
command_execute "$ENV" tok abc123 '{"id":"c3","type":"update","params":{"tag":"v1.2.0"}}'
[ "$(status_of)" = "failed" ] && good "reported failed" || bad "reported $(status_of)"
[ "$(env_get "$ENV" IMAGE_TAG)" = "v1.0.0" ] && good "back on the old version" || bad "left on $(env_get "$ENV" IMAGE_TAG)"
[ "$(grep -c 'compose up' "$COMPOSE_LOG")" -ge 2 ] && good "and started again on it" || bad "left the host with nothing running"
[[ "$(error_of)" == *"Rolled back"* ]] && good "says so" || bad "said '$(error_of)'"
UP_RC=0

echo
echo "an update for a deployment this host no longer runs changes nothing"
fresh
TARGETS_RC=1
command_execute "$ENV" tok abc123 '{"id":"c4","type":"update","params":{"tag":"v1.2.0"}}'
[ "$(env_get "$ENV" IMAGE_TAG)" = "v1.0.0" ] && good "the version is left alone" || bad "moved someone else's deployment"
[ ! -s "$COMPOSE_LOG" ] && good "the stack is untouched" || bad "ran compose anyway"
TARGETS_RC=0

echo
echo "an update with no version named is refused"
fresh
command_execute "$ENV" tok abc123 '{"id":"c5","type":"update","params":{}}'
[ "$(status_of)" = "failed" ] && good "fails" || bad "accepted it"
[ ! -s "$COMPOSE_LOG" ] && good "without touching the stack" || bad "ran compose anyway"

echo
echo "$P passed, $F failed"
[ "$F" -eq 0 ]
