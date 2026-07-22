#!/bin/bash
set -euo pipefail

: "${BACKUP_ROOT:=/backups}"

mkdir -p \
  "$BACKUP_ROOT/mongo" \
  "$BACKUP_ROOT/minio" \
  "$BACKUP_ROOT/volumes" \
  /var/log

touch /var/log/backup.log

echo "[$(date -u +%FT%TZ)] backup-srv starting (TZ=${TZ:-UTC})"

# Ad-hoc mode: `docker compose run --rm backup run backup-mongo.sh`
if [[ "${1:-}" == "run" ]]; then
  shift
  script="/opt/backup/scripts/$1"
  shift
  exec "$script" "$@"
fi

# Otherwise run cron in the foreground and tail the log to stdout.
crond -f -L /dev/stdout &
tail -F /var/log/backup.log
