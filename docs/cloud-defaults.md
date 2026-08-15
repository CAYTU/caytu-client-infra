# Cloud defaults: managed vs self-hosted messaging

The stack has two mutually-exclusive paths for MQTT ingest and WebRTC signaling:

| Path | MQTT | WebRTC signaling | STUN/TURN | When |
|---|---|---|---|---|
| **Self-hosted** | `mqtt-broker` (mosquitto) container, or an external broker your fleet already publishes to | `signaling-server` container | `coturn` container | Local, on-prem, generic SSH, GCP |
| **AWS managed** | AWS IoT Core | Kinesis Video Streams (KVS) WebRTC signaling channel | KVS `GetIceServerConfig` (Amazon-managed TURN) | AWS single-instance, AWS cluster |

## Why the split

The self-hosted path keeps every dependency inside the compose network — good for laptops, air-gapped installs, and anywhere internet egress is metered. It also lets you run the same stack against your own MQTT broker (Vernemq, EMQX, HiveMQ), which is common when the customer already has an IoT platform.

The AWS-managed path leans on services that already handle TLS termination, ICE candidate discovery, and the "peer NAT hell" problem that self-hosted TURN eventually runs into at scale. Cheaper to operate, but only viable on AWS.

GCP has no equivalent to either KVS (retired IoT Core in 2023, no managed WebRTC signaling), so GCP targets stay on the self-hosted path.

## How the CLI picks

`caytu-client` sets `COMPOSE_PROFILES` automatically based on the target. Precedence, high to low:

1. `COMPOSE_PROFILES` already exported in your shell — wins outright.
2. `COMPOSE_PROFILES=...` in `compose/.env.<target>` — wins if #1 unset.
3. CLI's per-target default from `default_profiles_for` in [scripts/caytu-client](../scripts/caytu-client):

| Target | Profiles activated | signaling-server | coturn | MQTT / signaling source |
|---|---|---|---|---|
| `local` | `self-hosted` | ✓ | ✗ | in-stack signaling; laptop MQTT via `mqtt-broker` profile |
| `onprem` | `self-hosted,turn,mqtt-broker` | ✓ | ✓ | in-stack signaling and MQTT (mosquitto) |
| `ssh` | `self-hosted,turn,mqtt-broker` | ✓ | ✓ | in-stack signaling and MQTT (mosquitto) |
| `gcp-single` | `self-hosted,turn,mqtt-broker` | ✓ | ✓ | in-stack (no managed GCP path) |
| `gcp-cluster` (phase 4) | `self-hosted,turn` | ✓ (StatefulSet/Deployment) | ✓ (Deployment) | in-cluster (no managed GCP path) |
| `self-managed-k8s` (phase 4) | `self-hosted,turn` | ✓ (Deployment) | ✓ (Deployment) | in-cluster; operator's own MQTT if needed |
| `aws-single` (phase 2) | *(none)* | ✗ | ✗ | AWS IoT Core + KVS WebRTC |
| `aws-cluster` (phase 4) | *(none)* | ✗ | ✗ | AWS IoT Core + KVS WebRTC |

For the k8s targets, `COMPOSE_PROFILES` is informational — the actual enable/disable is done by the kustomize overlay under `kubernetes/overlays/<target>/`. The `aws-eks` overlay omits the signaling-server and coturn manifests entirely; `gcp-gke` and `self-managed` include them.

Profiles that are never on by default (opt-in only, all targets): `search` (mongot), `vault`. The `mqtt-broker` profile is now on by default for compose-driven targets that don't use AWS IoT Core; disable it by setting `COMPOSE_PROFILES` explicitly if you point the streamer at an external broker.

## What actually changes for AWS targets

When `aws-*` is selected:

- **`signaling-server` container** does not start (profile `self-hosted` is off).
- **`coturn` container** does not start.
- **`mqtt-broker` (mosquitto)** does not start (was already opt-in via profile `mqtt-broker`).
- **backend + gstreamer-recorder** need `STREAMING_PROVIDER=kvs` set in `.env.aws-<single|cluster>`. The IoT **device certificate, private key and CA are not files** — they live in the encrypted `caytu_secrets` store in Mongo, loaded with `caytu-client secrets seed` (see [secrets.md](secrets.md)). Nothing is bind-mounted.
- **`mqtt-streamer`** points at `AWS_IOT_ENDPOINT` instead of a local broker.

The app expects these env vars for the KVS path (set them in `.env.aws-single`):

```bash
STREAMING_PROVIDER=kvs
SIGNALING_MODE=kvs
AWS_REGION=us-east-1
AWS_IOT_ENDPOINT=<account>.iot.us-east-1.amazonaws.com
AWS_IOT_ROLE_ALIAS=<alias>
KVS_SIGNALING_CHANNEL_ARN=arn:aws:kinesisvideo:...:channel/...
```

Endpoints and the role alias are configuration, not secrets, so they belong in
the env file — `caytu-client aws provision` fills them in from the Terraform
outputs. The certificate material is what goes in the vault.

## Manually overriding

**Run AWS with self-hosted signaling anyway** (uncommon; sometimes useful for testing):

```bash
COMPOSE_PROFILES=self-hosted,turn caytu-client -t aws-single up
```

**Run GCP with a 3rd-party managed signaling service (LiveKit Cloud, EMQX Cloud)**:
Set `SIGNALING_SERVER_INTERNAL_URL=https://your.livekit.cloud` and empty `COMPOSE_PROFILES` in `.env.gcp-single`. The compose stack won't start signaling-server; the backend routes to your provider.

**Debug what profiles are actually active:**

```bash
caytu-client -t <target> ps --services       # what's about to run
docker compose --env-file compose/.env.<target> \
  -f compose/docker-compose.yml \
  -f compose/docker-compose.<local|remote>.yml \
  config --profiles                          # profiles compose sees
```
