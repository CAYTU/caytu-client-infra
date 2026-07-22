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
RUN curl -fsSLo /usr/local/bin/mc https://dl.min.io/client/mc/release/linux-amd64/mc && \
    chmod +x /usr/local/bin/mc

COPY scripts /opt/backup/scripts
COPY crontab /etc/crontabs/root
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /opt/backup/scripts/*.sh /entrypoint.sh

ENV BACKUP_ROOT=/backups \
    PATH="/opt/backup/scripts:${PATH}"

ENTRYPOINT ["/sbin/tini", "--", "/entrypoint.sh"]
