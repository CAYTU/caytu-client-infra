#!/bin/bash
set -euo pipefail

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
out_dir="${BACKUP_ROOT}/volumes"

for vol_path in /volumes/*; do
  [[ -d "$vol_path" ]] || continue
  vol_name="$(basename "$vol_path")"
  # Skip mongodb-data — mongodump already captures a consistent snapshot.
  [[ "$vol_name" == "mongodb-data" ]] && continue

  out="${out_dir}/${vol_name}-${stamp}.tar.gz"
  echo "[$(date -u +%FT%TZ)] tar $vol_path -> $out"
  tar -czf "$out" -C "$vol_path" .
  ls -lh "$out"
done
