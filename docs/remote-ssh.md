# Remote SSH deployment

For any Linux host you can SSH into: bare-metal on-prem, a Hetzner/DO/Linode VPS, a customer's server. If it's on AWS or GCP and you'd rather have Terraform provision the box, see phases 2 and 3.

## What ends up on the host

```
/opt/caytu-client/
├── compose/          # rsynced from your workstation (docker-compose*.yml, nginx/, monitoring/, backup/)
├── backups/          # local snapshots produced by backup-srv
├── certbot/          # Let's Encrypt state
└── ... docker named volumes live under /var/lib/docker/volumes/
```

The single env file (`compose/.env.ssh`) also lives under `/opt/caytu-client/compose/`, mode 600, gitignored on your workstation. Application secrets go in the encrypted Mongo store — see [secrets.md](secrets.md).

## One-time host bootstrap

On the target host, as a user with sudo:

```bash
curl -fsSL https://raw.githubusercontent.com/CAYTU/caytu-client-infra/main/scripts/bootstrap.sh | sudo bash
```

This installs Docker + compose plugin + rsync + jq + aws cli, and creates `/opt/caytu-client` owned by the invoking user.

## From your workstation

```bash
# 1. tell the CLI where the box is
caytu-client -t ssh state set ssh_host 203.0.113.10
caytu-client -t ssh state set ssh_user ubuntu
caytu-client -t ssh state set ssh_key_path ~/.ssh/id_ed25519

# 2. verify
caytu-client -t ssh doctor

# 3. seed env
caytu-client -t ssh init                     # copies .env.example -> .env.ssh
$EDITOR compose/.env.ssh
# Fill in at least:
#   IMAGE_REGISTRY=<your registry, e.g. 688...dkr.ecr.us-east-1.amazonaws.com>
#   IMAGE_TAG=<your tag, e.g. latest-arm64>
#   MINIO_ROOT_USER / MINIO_ROOT_PASSWORD
#   TURN_SECRET
#   CAYTU_DOMAIN + CAYTU_LETSENCRYPT_EMAIL
# That one file configures every service. Application secrets (JWT keys, API
# keys, IoT device certs) go in the encrypted Mongo store instead:
#   caytu-client -t ssh secrets seed --in vault.json

# 4. registry login on your side, if you're pulling from a private registry
aws ecr get-login-password --region us-east-1 | \
  ssh -i ~/.ssh/id_ed25519 ubuntu@203.0.113.10 'docker login --username AWS --password-stdin 688...dkr.ecr.us-east-1.amazonaws.com'

# 5. push compose tree + env files
caytu-client -t ssh env push

# 6. start it
caytu-client -t ssh up
caytu-client -t ssh ps
caytu-client -t ssh logs backend

# 7. issue the TLS cert (nginx must be reachable on :80 for the ACME challenge)
caytu-client -t ssh ssl bootstrap client.example.com ops@example.com
```

## Rolling out a new version

```bash
# on the workstation, if compose or nginx config changed:
caytu-client -t ssh env push

# pull new images and recreate services (all or specific):
caytu-client -t ssh deploy
caytu-client -t ssh deploy backend frontend
```

## Firewall

Open on the host:

- `22/tcp`  SSH (restrict to operator IPs)
- `80/tcp`  HTTP (redirects + Let's Encrypt challenges)
- `443/tcp` HTTPS (all app traffic)
- `3478/tcp+udp`, `5349/tcp+udp`, `49152-49252/udp`  TURN (only if `STREAMING_PROVIDER=self-hosted`)
- `1885/tcp`, `8883/tcp` MQTT (only if `--profile mqtt-broker`)

## Monitoring

```bash
caytu-client -t ssh monitor up
caytu-client -t ssh monitor tunnel grafana   # ssh tunnel to http://localhost:3005
caytu-client -t ssh monitor tunnel dozzle    # -> http://localhost:8005
```

Grafana/Dozzle bind to `127.0.0.1` on the remote by default — they're only reachable via the tunnel. Change `GRAFANA_BIND` in `.env.ssh` if you want them public (behind your own auth!).

## Backups

```bash
caytu-client -t ssh backup enable            # builds + starts backup-srv
caytu-client -t ssh backup run backup-mongo.sh   # ad-hoc
caytu-client -t ssh backup list
caytu-client -t ssh backup restore mongo /backups/mongo/mongo-20260701T020000Z.gz
```

See [backup-restore.md](backup-restore.md) for the full lifecycle including restic offsite config.
