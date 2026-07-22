#!/bin/bash
set -euo pipefail

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
out="${BACKUP_ROOT}/mongo/mongo-${stamp}.gz"

uri="mongodb://${MONGO_HOST}:${MONGO_PORT}/${MONGO_DATABASE}?replicaSet=rs0&directConnection=true"

auth=()
if [[ -n "${MONGO_USERNAME:-}" ]]; then
  auth=(--username "$MONGO_USERNAME" --password "$MONGO_PASSWORD" --authenticationDatabase admin)
fi

echo "[$(date -u +%FT%TZ)] mongodump -> $out"
mongodump --uri "$uri" "${auth[@]}" --gzip --archive="$out"

# Simple integrity check: file exists and is non-empty
[[ -s "$out" ]] || { echo "backup empty!" >&2; exit 1; }

ls -lh "$out"
