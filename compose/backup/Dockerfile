# The MinIO client is copied from the MinIO server image, which ships it at
# /usr/bin/mc (a static Go binary, so it runs on Alpine). MinIO no longer
# publishes community binaries, and the download this replaced was hard-wired
# to linux-amd64 — wrong on Graviton hosts. From a multi-arch image, BuildKit
# takes the stage for the platform being built.
ARG MINIO_IMAGE=688544396352.dkr.ecr.us-east-1.amazonaws.com/caytu-client-minio:RELEASE.2025-09-07T16-13-09Z
FROM ${MINIO_IMAGE} AS minio

FROM alpine:3.20

RUN apk add --no-cache \
    bash \
    ca-certificates \
    curl \
    dcron \
    mongodb-tools \
    restic \
    tar \
    tini \
    tzdata

# MinIO client for bucket mirroring
COPY --from=minio /usr/bin/mc /usr/local/bin/mc

COPY scripts /opt/backup/scripts
COPY crontab /etc/crontabs/root
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /opt/backup/scripts/*.sh /entrypoint.sh

ENV BACKUP_ROOT=/backups \
    PATH="/opt/backup/scripts:${PATH}"

ENTRYPOINT ["/sbin/tini", "--", "/entrypoint.sh"]
