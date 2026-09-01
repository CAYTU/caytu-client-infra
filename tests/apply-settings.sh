#!/usr/bin/env bash
# The console records settings; this is the host collecting and using them.
set -uo pipefail
cd "$(dirname "$0")/.."

P=0; F=0
ok()  { echo "  PASS  $1"; P=$((P+1)); }
bad() { echo "  FAIL  $1"; F=$((F+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ENV="$TMP/.env.test"

env_get() { grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-; }
env_upsert() {
  local f=$1 k=$2 v=$3
  grep -qE "^$k=" "$f" 2>/dev/null && sed -i "s|^$k=.*|$k=$v|" "$f" || printf '%s=%s\n' "$k" "$v" >> "$f"
}
instance_platform_url() { echo "http://platform.test"; }
compose() { echo "compose $*" >> "$TMP/compose.log"; }
eval "$(sed -n '/^fetch_and_apply_settings()/,/^}/p' scripts/caytu-client)"

BODY=""; CODE=0
curl() { [ "$CODE" -ne 0 ] && return "$CODE"; printf '%s' "$BODY"; }

echo "settings the console holds are written to the env file"
printf 'CAYTU_METERING_TOKEN=ct_tok\nKEEP_ME=local-only\n' > "$ENV"
BODY='{"settings":{"OPENAI_API_KEY":"sk-abc","TURN_SECRET":"turn-xyz"},"secrets":{},"files":{}}'; CODE=0
out="$(fetch_and_apply_settings "$ENV" "abc123")"
[ "$(env_get "$ENV" OPENAI_API_KEY)" = "sk-abc" ] && ok "a value is written" || bad "not written"
[ "$(env_get "$ENV" TURN_SECRET)" = "turn-xyz" ] && ok "a second value is written" || bad "second not written"
[ "$out" = "2" ] && ok "reports how many" || bad "reported '$out'"

# The env file also holds values only this host has. A wholesale rewrite of the
# file would lose them, which is why keys are written one at a time.
[ "$(env_get "$ENV" KEEP_ME)" = "local-only" ] \
  && ok "a key the console does not know is left alone" || bad "local key lost"

echo
echo "an existing value is replaced, not duplicated"
BODY='{"settings":{"OPENAI_API_KEY":"sk-new"},"secrets":{},"files":{}}'; CODE=0
fetch_and_apply_settings "$ENV" "abc123" >/dev/null
[ "$(env_get "$ENV" OPENAI_API_KEY)" = "sk-new" ] && ok "replaced" || bad "not replaced"
[ "$(grep -c '^OPENAI_API_KEY=' "$ENV")" = "1" ] && ok "written once" || bad "duplicated"

echo
echo "nothing to do is not a failure"
BODY='{"settings":{},"secrets":{},"files":{}}'; CODE=0
out="$(fetch_and_apply_settings "$ENV" "abc123")"; rc=$?
[ "$rc" -eq 0 ] && ok "succeeds" || bad "failed with $rc"
[[ "$out" == *"no settings"* ]] && ok "says so, rather than claiming an apply" || bad "said '$out'"

echo
echo "a host with no credential says why"
printf 'KEEP=1\n' > "$TMP/.env.notoken"
out="$(fetch_and_apply_settings "$TMP/.env.notoken" "abc123")"; rc=$?
[ "$rc" -ne 0 ] && ok "fails" || bad "succeeded without a credential"
[[ "$out" == *"credential"* ]] && ok "names the reason" || bad "said '$out'"

echo
echo "a platform that does not answer changes nothing"
before="$(cat "$ENV")"
CODE=7
out="$(fetch_and_apply_settings "$ENV" "abc123")"; rc=$?
[ "$rc" -ne 0 ] && ok "fails" || bad "reported success"
[ "$before" = "$(cat "$ENV")" ] && ok "file untouched" || bad "file was changed anyway"

echo
echo "a secret goes to the store, never the env file"
: > "$TMP/compose.log"
printf 'CAYTU_METERING_TOKEN=ct_tok\n' > "$TMP/.env.split"
BODY='{"settings":{"LOG_LEVEL":"debug"},"secrets":{"OPENAI_API_KEY":"sk-secret"},"files":{}}'; CODE=0
out="$(fetch_and_apply_settings "$TMP/.env.split" "abc123")"
[ "$(env_get "$TMP/.env.split" LOG_LEVEL)" = "debug" ] && ok "the ordinary one is written" || bad "not written"
grep -q "OPENAI_API_KEY" "$TMP/.env.split" && bad "the secret was written to the env file" || ok "the secret is not in the env file"
grep -q "seal-secrets" "$TMP/compose.log" && ok "the secret is sealed into the store" || bad "never sealed"
[ "$out" = "2" ] && ok "both counted" || bad "counted '$out'"

echo
echo "a deployment with no version pinned gets the current release"
eval "$(sed -n '/^current_release()/,/^}/p' ../wt-infra-aws/scripts/caytu-client 2>/dev/null || sed -n '/^current_release()/,/^}/p' scripts/caytu-client)"
printf 'CAYTU_METERING_TOKEN=ct_tok\n' > "$TMP/.env.ver"
BODY='{"versions":[{"tag":"v1.0.4"},{"tag":"v1.0.3"}],"available":true}'; CODE=0
[ "$(current_release "$TMP/.env.ver")" = "v1.0.4" ] && ok "takes the newest" || bad "took something else"
# A pin is not a default, it is the only option.
BODY='{"versions":[{"tag":"v1.0.4"}],"pinned":"v1.0.2","available":true}'; CODE=0
[ "$(current_release "$TMP/.env.ver")" = "v1.0.2" ] && ok "a pinned organization stays pinned" || bad "ignored the pin"
# Better to say nothing is pinned than to pick a version nobody chose.
CODE=7
[ -z "$(current_release "$TMP/.env.ver")" ] && ok "says nothing when the platform is unreachable" || bad "guessed"

echo
echo "$P passed, $F failed"
[ "$F" -eq 0 ]
