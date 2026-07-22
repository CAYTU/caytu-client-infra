# Backup & restore

The backup overlay adds a `backup` container that runs cron and produces daily snapshots, then (optionally) pushes encrypted copies offsite via [restic](https://restic.net/).

## What gets backed up (UTC)

| Time | What | How | Where |
|---|---|---|---|
| 02:00 | MongoDB | `mongodump --gzip --archive` | `./backups/mongo/mongo-<stamp>.gz` |
| 02:30 | MinIO buckets | `mc mirror` → `tar -czf` | `./backups/minio/minio-<stamp>.tar.gz` |
| 03:00 | Docker volumes (except mongodb-data) | `tar -czf` | `./backups/volumes/<vol>-<stamp>.tar.gz` |
| 03:30 | Offsite copy | `restic backup` | `RESTIC_REPOSITORY` |
| 04:00 | Local prune | `find -mtime` | keeps `BACKUP_LOCAL_RETENTION_DAYS` (default 7) |

MongoDB is intentionally *not* tarred as a volume — a live copy of `/data/db` isn't consistent. `mongodump` is authoritative.

## Turning it on

```bash
caytu-client -t <target> backup enable
caytu-client -t <target> backup run backup-mongo.sh   # ad-hoc test
caytu-client -t <target> backup list
```

## Offsite (restic)

Leave `RESTIC_REPOSITORY` empty in `.env.<target>` and the offsite step is skipped. To enable, pick one:

```bash
# AWS S3
RESTIC_REPOSITORY=s3:s3.amazonaws.com/caytu-client-backups
RESTIC_PASSWORD=<long random>
RESTIC_AWS_ACCESS_KEY_ID=AKIA...
RESTIC_AWS_SECRET_ACCESS_KEY=...

# Backblaze B2
RESTIC_REPOSITORY=b2:caytu-client-backups:/
RESTIC_B2_ACCOUNT_ID=<app-key-id>
RESTIC_B2_ACCOUNT_KEY=<app-key>

# GCS
RESTIC_REPOSITORY=gs:caytu-client-backups:/
RESTIC_GCS_KEYFILE=/secrets/gcs-backup-key.json
# also uncomment the volume mount in docker-compose.backup.yml

# SFTP
RESTIC_REPOSITORY=sftp:backup@example.com:/srv/backups/caytu-client
```

Store `RESTIC_PASSWORD` somewhere durable outside the deployed host — you cannot decrypt the backups without it.

Retention (in the same env file):

```bash
RESTIC_KEEP_DAILY=7
RESTIC_KEEP_WEEKLY=4
RESTIC_KEEP_MONTHLY=6
```

## Restore

Restores are manual on purpose. The backup container refuses to touch running data unless you set `RESTORE_CONFIRM=yes`.

**MongoDB (drops existing collections, then restores):**

```bash
caytu-client -t <target> backup restore mongo /backups/mongo/mongo-20260601T020000Z.gz
```

**MinIO (destructive mirror of the snapshot):**

```bash
caytu-client -t <target> backup restore minio /backups/minio/minio-20260601T023000Z.tar.gz
```

**A docker volume (e.g. gstreamer-recordings):**

```bash
# on the remote host, from /opt/caytu-client/compose
docker compose stop gstreamer-recorder
docker run --rm \
  -v caytu-client_gstreamer-recordings:/restore \
  -v $(pwd)/backups/volumes:/src:ro \
  alpine sh -c 'rm -rf /restore/* && tar -xzf /src/gstreamer-recordings-<stamp>.tar.gz -C /restore'
docker compose start gstreamer-recorder
```

**From restic (pulls the archive back, then restore as above):**

```bash
docker compose run --rm backup sh -c 'restic snapshots'
docker compose run --rm backup sh -c 'restic restore <snapshot-id> --target /backups'
```

## Monitoring backup runs

```bash
caytu-client -t <target> logs backup     # follow the cron log
caytu-client -t <target> backup list     # show local archives
```

Wire the log into your alerting (loki, papertrail, cloudwatch — whatever) and alert on absence of a successful "mongodump ->" line in the past 24 hours.
