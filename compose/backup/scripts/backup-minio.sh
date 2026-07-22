#!/bin/bash
set -euo pipefail

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
out_root="${BACKUP_ROOT}/minio/${stamp}"
mkdir -p "$out_root"

mc alias set src "${MINIO_ENDPOINT}" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" --api s3v4 >/dev/null

for bucket in ${MINIO_BUCKETS:-}; do
  echo "[$(date -u +%FT%TZ)] mirror src/${bucket} -> ${out_root}/${bucket}"
  mkdir -p "${out_root}/${bucket}"
  mc mirror --overwrite --remove "src/${bucket}" "${out_root}/${bucket}"
done

echo "[$(date -u +%FT%TZ)] compressing ${out_root}"
tar -C "${BACKUP_ROOT}/minio" -czf "${BACKUP_ROOT}/minio/minio-${stamp}.tar.gz" "${stamp}"
rm -rf "${out_root}"

ls -lh "${BACKUP_ROOT}/minio/minio-${stamp}.tar.gz"
