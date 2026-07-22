#!/bin/bash
set -euo pipefail

if [[ -z "${RESTIC_REPOSITORY:-}" ]]; then
  echo "[$(date -u +%FT%TZ)] RESTIC_REPOSITORY empty; skipping offsite upload"
  exit 0
fi

# Initialize the repo the first time. `restic init` fails if it already exists,
# which is fine — treat "already initialized" as a no-op.
if ! restic snapshots >/dev/null 2>&1; then
  echo "[$(date -u +%FT%TZ)] initializing restic repo at $RESTIC_REPOSITORY"
  restic init || true
fi

echo "[$(date -u +%FT%TZ)] restic backup ${BACKUP_ROOT}"
restic backup "${BACKUP_ROOT}" --tag caytu-client --host "$(hostname)"

echo "[$(date -u +%FT%TZ)] pruning old snapshots"
restic forget \
  --keep-daily   "${RESTIC_KEEP_DAILY:-7}" \
  --keep-weekly  "${RESTIC_KEEP_WEEKLY:-4}" \
  --keep-monthly "${RESTIC_KEEP_MONTHLY:-6}" \
  --prune
