#!/bin/bash
set -euo pipefail

if [[ "${RESTORE_CONFIRM:-}" != "yes" ]]; then
  echo "Refusing to restore without RESTORE_CONFIRM=yes"
  echo "Usage: docker compose run --rm -e RESTORE_CONFIRM=yes backup run restore-mongo.sh /backups/mongo/mongo-<stamp>.gz"
  exit 1
fi

archive="${1:-}"
[[ -f "$archive" ]] || { echo "no archive at $archive"; exit 1; }

uri="mongodb://${MONGO_HOST}:${MONGO_PORT}/${MONGO_DATABASE}?replicaSet=rs0&directConnection=true"
auth=()
if [[ -n "${MONGO_USERNAME:-}" ]]; then
  auth=(--username "$MONGO_USERNAME" --password "$MONGO_PASSWORD" --authenticationDatabase admin)
fi

echo "[$(date -u +%FT%TZ)] mongorestore from $archive (drops existing collections)"
mongorestore --uri "$uri" "${auth[@]}" --gzip --archive="$archive" --drop
