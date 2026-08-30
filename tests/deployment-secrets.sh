#!/usr/bin/env bash
# Every deployment gets its own secrets, and keeps the ones it already had.
set -uo pipefail
cd "$(dirname "$0")/.."

P=0; F=0
ok()  { echo "  PASS  $1"; P=$((P+1)); }
bad() { echo "  FAIL  $1"; F=$((F+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

env_get() { grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-; }
env_upsert() {
  local f=$1 k=$2 v=$3
  grep -qE "^$k=" "$f" 2>/dev/null && sed -i "s|^$k=.*|$k=$v|" "$f" || printf '%s=%s\n' "$k" "$v" >> "$f"
}
require_cmd() { command -v "$1" >/dev/null || { echo "missing $1"; exit 1; }; }
eval "$(sed -n '/^ensure_deployment_secrets()/,/^}/p' scripts/caytu-client)"

echo "an empty deployment gets everything it needs"
ENV="$TMP/.env.fresh"; : > "$ENV"
ensure_deployment_secrets "$ENV" >/dev/null
for k in JWT_SECRET MINIO_ROOT_USER MINIO_ROOT_PASSWORD TURN_SECRET \
         SIGNALING_AUTH_TOKEN SMS_ENCRYPTION_KEY MINIO_ACCESS_KEY MINIO_SECRET_KEY; do
  [ -n "$(env_get "$ENV" "$k")" ] && ok "$k set" || bad "$k empty"
done

# The whole reason this exists: the compose file falls back to minioadmin when
# these are empty, and nothing was filling them in.
[ "$(env_get "$ENV" MINIO_ROOT_PASSWORD)" != "minioadmin" ] \
  && ok "MinIO is not on the vendor default" || bad "MinIO left on minioadmin"

# The store and the env file keep the same pair under different names, and the
# two drifting is a deployment that cannot reach its own object storage.
[ "$(env_get "$ENV" MINIO_ACCESS_KEY)" = "$(env_get "$ENV" MINIO_ROOT_USER)" ] \
  && ok "access key matches the root user" || bad "access key drifted"
[ "$(env_get "$ENV" MINIO_SECRET_KEY)" = "$(env_get "$ENV" MINIO_ROOT_PASSWORD)" ] \
  && ok "secret key matches the root password" || bad "secret key drifted"

echo
echo "two deployments do not share a secret"
ENV2="$TMP/.env.other"; : > "$ENV2"
ensure_deployment_secrets "$ENV2" >/dev/null
[ "$(env_get "$ENV" MINIO_ROOT_PASSWORD)" != "$(env_get "$ENV2" MINIO_ROOT_PASSWORD)" ] \
  && ok "different MinIO password" || bad "same MinIO password on both"
[ "$(env_get "$ENV" JWT_SECRET)" != "$(env_get "$ENV2" JWT_SECRET)" ] \
  && ok "different JWT secret" || bad "same JWT secret on both"

echo
echo "a value already in use is never replaced"
# Re-provisioning must not lock a running deployment out of its own data.
ENV3="$TMP/.env.existing"
cat > "$ENV3" <<'INNER'
JWT_SECRET=chosen-by-hand
MINIO_ROOT_USER=existing-user
MINIO_ROOT_PASSWORD=existing-pass
INNER
ensure_deployment_secrets "$ENV3" >/dev/null
[ "$(env_get "$ENV3" JWT_SECRET)" = "chosen-by-hand" ] \
  && ok "JWT secret kept" || bad "JWT secret overwritten"
[ "$(env_get "$ENV3" MINIO_ROOT_USER)" = "existing-user" ] \
  && ok "MinIO user kept" || bad "MinIO user overwritten"
[ "$(env_get "$ENV3" MINIO_ROOT_PASSWORD)" = "existing-pass" ] \
  && ok "MinIO password kept" || bad "MinIO password overwritten"

# Running twice is what a re-provision does, and it must change nothing.
before="$(cat "$ENV3")"
ensure_deployment_secrets "$ENV3" >/dev/null
[ "$before" = "$(cat "$ENV3")" ] \
  && ok "running again changes nothing" || bad "second run rewrote the file"

echo
echo "$P passed, $F failed"
[ "$F" -eq 0 ]
