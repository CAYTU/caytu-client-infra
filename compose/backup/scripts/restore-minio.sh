#!/bin/bash
set -euo pipefail

if [[ "${RESTORE_CONFIRM:-}" != "yes" ]]; then
  echo "Refusing to restore without RESTORE_CONFIRM=yes"
  echo "Usage: docker compose run --rm -e RESTORE_CONFIRM=yes backup run restore-minio.sh /backups/minio/minio-<stamp>.tar.gz"
  exit 1
fi

archive="${1:-}"
[[ -f "$archive" ]] || { echo "no archive at $archive"; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "[$(date -u +%FT%TZ)] extracting $archive to $work"
tar -C "$work" -xzf "$archive"

stamp_dir="$(find "$work" -mindepth 1 -maxdepth 1 -type d | head -1)"
[[ -d "$stamp_dir" ]] || { echo "archive shape unexpected"; exit 1; }

mc alias set dst "${MINIO_ENDPOINT}" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" --api s3v4 >/dev/null

for bucket_dir in "$stamp_dir"/*/; do
  bucket="$(basename "$bucket_dir")"
  echo "[$(date -u +%FT%TZ)] mirror ${bucket_dir} -> dst/${bucket} (destructive)"
  mc mb "dst/${bucket}" --ignore-existing >/dev/null
  mc mirror --overwrite --remove "$bucket_dir" "dst/${bucket}"
done
