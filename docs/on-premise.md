# On-premise deployment

For running the production stack on a machine you own — a server at a customer site, a rack in your office, a NUC on someone's shop floor. Same compose stack as [remote-ssh](remote-ssh.md), but you're logged into the box directly instead of driving it over SSH.

Typical shape:

- Fixed IP on a LAN (`10.0.1.42`), no public DNS.
- No internet-reachable domain, so Let's Encrypt is not available.
- Operator wants the app running as a real service (nginx, prebuilt images, backups) — not the dev stack with hot reload.

## Prerequisites on the host

- Ubuntu / Debian / any Linux Docker supports
- Docker + compose plugin (run [`scripts/bootstrap.sh`](../scripts/bootstrap.sh) as root to install)
- `openssl` (for `ssl self-signed`)
- Access to your container registry (ECR, private registry, or `docker load` from tar)

## First run

```bash
git clone https://github.com/CAYTU/caytu-client-infra /opt/caytu-client-infra
cd /opt/caytu-client-infra

./scripts/caytu-client install
caytu-client -t onprem init            # creates compose/.env.onprem
$EDITOR compose/.env.onprem
```

At minimum set:

```bash
IMAGE_REGISTRY=<your registry>     # or leave empty if you're 'docker load'-ing images
IMAGE_TAG=<your tag>
MINIO_ROOT_USER=<user>
MINIO_ROOT_PASSWORD=<strong pw>
TURN_SECRET=<random 32 bytes>
CAYTU_DOMAIN=10.0.1.42             # bare IP is fine; also accepts LAN hostnames
GRAFANA_ADMIN_PASSWORD=<strong pw>

# Signaling: on-prem uses the `static` auth driver — backend, gstreamer and
# the browser all present this shared token, and the signaling server looks
# it up in compose/secrets/signaling-tokens.json.
SIGNALING_AUTH_DRIVER=static
SIGNALING_AUTH_TOKEN=<openssl rand -hex 32>
```

That single file is the whole configuration — every service reads it. Application
secrets (JWT keys, API keys, device certs) go in the encrypted Mongo store
instead, via `caytu-client -t onprem secrets seed --in vault.json`. See
[secrets.md](secrets.md).

## Services that start by default on `onprem`

The `onprem` target activates these compose profiles:

- `self-hosted` — `signaling-server` (in-stack WebRTC signaling)
- `turn` — `coturn` (STUN/TURN for clients behind NAT)
- `mqtt-broker` — mosquitto (local MQTT broker; AWS IoT Core is not used on-prem)

The `mqtt-streamer` runs unconditionally and, out of the box, connects to the
local `mqtt-broker` container on port 1883. Its config lives in
[`compose/mqtt-streamer/streamer_config.yaml`](../compose/mqtt-streamer/streamer_config.yaml.example),
seeded from the committed `.example` on first `up`. Edit it to list your real
devices and set the ingest API token — the streamer refuses to boot with
placeholders when it starts consuming real traffic.

## Files the CLI seeds from templates on first `up`

Before starting containers, `caytu-client up` copies these templates into
place if they don't already exist. Each has `REPLACE_WITH_*` placeholders you
must swap for real values before production use:

| Seeded file | From template | What to edit |
|---|---|---|
| `compose/secrets/signaling-tokens.json` | `secrets/signaling-tokens.example.json` | Replace the JSON key with the value of `SIGNALING_AUTH_TOKEN` above |
| `compose/mqtt-streamer/streamer_config.yaml` | `mqtt-streamer/streamer_config.yaml.example` | Ingest `x-api-token`, device list |

Both real files are gitignored — they're per-operator secrets.

Log into your registry, then start:

```bash
# for AWS ECR:
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <account>.dkr.ecr.us-east-1.amazonaws.com

caytu-client -t onprem up
caytu-client -t onprem ps
caytu-client -t onprem logs backend
```

## The initial admin email

On first boot, if the DB has zero users, the backend creates a superAdmin from
`INITIAL_ADMIN_EMAIL` and mails them a "set your password" link. Two things
must be in place for that email to actually leave the host:

1. **`INITIAL_ADMIN_EMAIL` set** in `compose/.env.onprem`. Empty means no
   superAdmin gets created — nothing to send. `INITIAL_ADMIN_NAME` is
   optional but nice.
2. **SMTP credentials.** The backend checks two sources in order (see
   `backend/src/services/email-service.ts`):
   - `SystemSettings.emailProvider` in Mongo, configured later via the Space
     admin UI. Wins when enabled, but you can only reach the UI *after* you
     sign in, so it can't send the very first email.
   - `EMAIL_*` env vars in `.env.onprem`, with **`EMAIL_PASSWORD` in the
     encrypted secret store** (not in `.env`). This is the fallback that
     covers first boot.

Configure the env fallback:

```bash
# in compose/.env.onprem
EMAIL_HOST=smtp.gmail.com
EMAIL_PORT=587
EMAIL_SECURE=false                     # true for implicit TLS on 465
EMAIL_USER=<sender>@caytu.com
EMAIL_FROM=<sender>@caytu.com
EMAIL_FROM_NAME=Caytu Client
```

Seed the password into the encrypted store. The store takes an already-encrypted
`vault.json`; the plaintext template you fill in first is
[`compose/vault/.env.secrets.example`](../compose/vault/.env.secrets.example):

```bash
cd compose/vault
cp .env.secrets.example .env.secrets
$EDITOR .env.secrets                # fill in EMAIL_PASSWORD (and anything else)

# encrypt-secrets.sh lives in the caytu-client app repo. The shard MUST match
# CAYTU_SECRET_STORE_KEY in compose/.env.onprem — that's how the backend
# derives the same key at runtime.
SECRET_STORE_KEY_B64=<same value as CAYTU_SECRET_STORE_KEY> \
CUSTOMER_ID=<your customer id> \
  /path/to/caytu-client/encrypt-secrets.sh --input .env.secrets --out vault.json

caytu-client -t onprem secrets seed --in vault.json
caytu-client -t onprem restart backend
```

Both `.env.secrets` and `vault.json` are gitignored — the `.example` template
is the only file that stays committed. See [secrets.md](secrets.md) for the
full model (what lives in Mongo vs `.env`, how re-seeding behaves, how the
anti-rollback ratchet works).

### If the email never arrives

The setup is designed to fail-soft — if SMTP is missing or misconfigured, the
superAdmin is still created and the setup link is written to the backend log.
Grab it directly:

```bash
docker compose logs backend | grep -Ei "set-password|setup initialization|claim link"
```

Open the URL, set the password, sign in. Then configure the SMTP provider
properly in the admin UI so later emails (password resets, alerts) work.

### To retry the initial-email flow

The initial-admin logic runs only when the users collection is empty. If it
ran once with SMTP misconfigured and you want another attempt after fixing
the config, drop the collection and restart the backend:

```bash
docker compose exec mongodb mongosh caytu --eval 'db.users.deleteMany({})'
docker compose restart backend
```

## TLS on a fixed IP — three choices

### 1. Self-signed cert (recommended for LAN)

```bash
caytu-client -t onprem ssl self-signed 10.0.1.42
```

Generates a 10-year cert with `10.0.1.42` as both IP and DNS SAN, drops it into `compose/certbot/conf/live/10.0.1.42/`, rewrites `nginx/conf.d/default.conf` to reference it, restarts nginx.

Browsers will warn on first visit. To silence:

- Copy `compose/certbot/conf/live/10.0.1.42/fullchain.pem` to each client machine.
- Import it into the OS/browser trust store (Windows: "Trusted Root Certification Authorities"; macOS: Keychain → System → Certificates → drag → set to Always Trust; Linux/Firefox: about:preferences → Privacy & Security → View Certificates → Import).
- For fleets, push it via MDM (JAMF / Intune / Ansible).

### 2. Bring your own cert (from an internal CA)

If your org has an internal PKI:

```bash
caytu-client -t onprem ssl bring-your-own caytu.corp.local \
  /path/to/fullchain.pem /path/to/privkey.pem
```

Same layout, no browser warnings for machines that already trust your internal CA.

### 3. HTTP-only (no TLS)

For truly closed LANs where TLS is more trouble than it's worth:

```bash
caytu-client -t onprem ssl http-only
```

Swaps the TLS nginx config for the HTTP-only variant. Everything runs on port 80. **Don't do this if the network is untrusted** — passwords fly plaintext.

Switching back later is `ssl self-signed <host>` — the CLI restores the TLS config from the `.disabled` backup.

## Firewall on the host

Open on the LAN interface:

- `80/tcp` if `ssl http-only`, otherwise for HTTPS redirects
- `443/tcp` if self-signed or bring-your-own
- `3478/tcp+udp`, `5349/tcp+udp`, `49152-49252/udp` if `STREAMING_PROVIDER=self-hosted`
- `1883/tcp` for the local mosquitto broker (on by default; only needs to be LAN-reachable if devices publish from other hosts)

Restrict to the LAN CIDR — no reason for these to be reachable from the general internet.

## Updating

New images pushed to your registry:

```bash
caytu-client -t onprem deploy
```

Or specific services:

```bash
caytu-client -t onprem deploy backend frontend
```

Compose file changes (rare):

```bash
cd /opt/caytu-client-infra
git pull
caytu-client -t onprem up      # picks up the new compose files
```

## Air-gapped installs

No registry access at all?

1. On a workstation with registry access:
   ```bash
   docker pull <registry>/backend:<tag>
   docker pull <registry>/frontend:<tag>
   # ... etc for signaling, gstreamer-recorder, mqtt-streamer
   docker save <registry>/backend:<tag> ... > images.tar
   ```
2. Transfer `images.tar` to the on-prem host.
3. On the host:
   ```bash
   docker load < images.tar
   caytu-client -t onprem up
   ```

Set `IMAGE_REGISTRY` in `.env.onprem` to whatever tag the images were saved under.

## Monitoring and backups

Both work identically to remote-ssh:

```bash
caytu-client -t onprem monitor up
open http://localhost:3005          # grafana (no tunnel needed, you're on the box)

caytu-client -t onprem backup enable
caytu-client -t onprem backup run backup-mongo.sh
```

For offsite backups without internet, point `RESTIC_REPOSITORY` at an SFTP target that lives inside your network (e.g. a NAS):

```bash
RESTIC_REPOSITORY=sftp:backup@nas.corp.local:/volume1/caytu-backups
```
