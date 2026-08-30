#!/usr/bin/env bash
# The deployment's key shard comes from the platform, not from the image.
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
eval "$(sed -n '/^fetch_secret_shard()/,/^}/p' scripts/caytu-client)"

# Stand in for the platform.
BODY=""; CODE=0
curl() { [ "$CODE" -ne 0 ] && return "$CODE"; printf '%s' "$BODY"; }

echo "a shard from the platform is written"
printf 'CAYTU_METERING_TOKEN=ct_tok\n' > "$ENV"
BODY='{"shard":"c2hhcmQtZnJvbS10aGUtcGxhdGZvcm0="}'; CODE=0
fetch_secret_shard "$ENV" "abc123"
[ "$(env_get "$ENV" CAYTU_SECRET_STORE_KEY)" = "c2hhcmQtZnJvbS10aGUtcGxhdGZvcm0=" ] \
  && ok "written to the env file" || bad "not written"
[ "$(stat -c %a "$ENV")" = "600" ] && ok "file kept at 600" || bad "permissions not tightened"

echo
echo "an existing shard is never replaced"
printf 'CAYTU_METERING_TOKEN=ct_tok\nCAYTU_SECRET_STORE_KEY=already-sealed-with-this\n' > "$ENV"
BODY='{"shard":"a-different-one"}'
fetch_secret_shard "$ENV" "abc123"
[ "$(env_get "$ENV" CAYTU_SECRET_STORE_KEY)" = "already-sealed-with-this" ] \
  && ok "re-provisioning cannot change the key a store was sealed with" || bad "shard was overwritten"

echo
echo "no shard on the platform is not an error"
printf 'CAYTU_METERING_TOKEN=ct_tok\n' > "$ENV"
BODY=""; CODE=0
fetch_secret_shard "$ENV" "abc123" && ok "returns cleanly" || bad "failed on an empty answer"
[ -z "$(env_get "$ENV" CAYTU_SECRET_STORE_KEY)" ] && ok "writes nothing, so the baked shard is used" || bad "wrote something"

echo
echo "an unreachable platform does not stop provisioning"
BODY=""; CODE=7
fetch_secret_shard "$ENV" "abc123" && ok "returns cleanly" || bad "failed the rollout"

echo
echo "no token means no request"
printf '# nothing\n' > "$ENV"; CODE=0; BODY='{"shard":"should-not-be-used"}'
fetch_secret_shard "$ENV" "abc123"
[ -z "$(env_get "$ENV" CAYTU_SECRET_STORE_KEY)" ] && ok "an unenrolled host asks for nothing" || bad "asked anyway"

printf '\n  %d passed, %d failed\n' "$P" "$F"; [ "$F" -eq 0 ]
