#!/bin/bash
set -euo pipefail

: "${LOCAL_RETENTION_DAYS:=7}"

echo "[$(date -u +%FT%TZ)] pruning local backups older than ${LOCAL_RETENTION_DAYS} days"
find "${BACKUP_ROOT}" -type f -mtime "+${LOCAL_RETENTION_DAYS}" -print -delete
find "${BACKUP_ROOT}" -type d -empty -not -path "${BACKUP_ROOT}" -print -delete
