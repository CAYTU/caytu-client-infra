# GCP single-instance deployment

Full stack on one GCE VM with Terraform-managed provisioning: instance, static IP, firewall rules, Artifact Registry, GCS backup bucket, service account for pull + storage auth. Self-hosted messaging (mosquitto / signaling-server / coturn) — GCP has no managed equivalent to AWS IoT Core (retired 2023) or KVS.

## Prerequisites on your workstation

- `gcloud` CLI, authenticated:
  ```bash
  gcloud auth login
  gcloud auth application-default login
  gcloud config set project <YOUR_PROJECT>
  ```
- Terraform ≥ 1.6
- `jq`, `rsync`, `docker`
- The `caytu-client` CLI installed

The identity you use needs to create: Compute Engine, Static IP, VPC firewall rules, service accounts, Artifact Registry, Cloud Storage buckets, plus permission to grant IAM to the service account. `roles/owner` is the easy path; for least-privilege the plan output enumerates every action Terraform performs.

## First run

```bash
caytu-client -t gcp-single doctor      # sanity checks
caytu-client -t gcp-single init        # writes compose/.env.gcp-single
caytu-client -t gcp-single gcp provision
# tfvars gets opened for you — set project_id + operator_ssh_cidrs at a minimum
```

After `gcp provision`, state and env have been patched with:

- `ssh_host = <static IP>`
- `ssh_user`, `ssh_key_path`
- `IMAGE_REGISTRY = <region>-docker.pkg.dev/<project>`
- `RESTIC_REPOSITORY = gs:<bucket>:/`
- `STREAMING_PROVIDER = self-hosted`

Push images:

```bash
caytu-client -t gcp-single gcp registry-login
docker push <region>-docker.pkg.dev/<project>/caytu-client-backend:<tag>
# ... etc for the other 4 services
```

Fill in per-service env, ship it, start:

```bash
$EDITOR compose/.env.backend compose/.env.frontend compose/.env.streamer compose/.env.signaling compose/.env.gstreamer
caytu-client -t gcp-single env push
caytu-client -t gcp-single up
caytu-client -t gcp-single logs backend
caytu-client -t gcp-single ssl bootstrap client.example.com ops@example.com
```

The VM's service account already grants Artifact Registry read, so `docker pull` on the box works without a login.

## Everyday verbs

```bash
caytu-client -t gcp-single deploy
caytu-client -t gcp-single logs backend
caytu-client -t gcp-single ps
caytu-client -t gcp-single ssh
caytu-client -t gcp-single gcp allow-me          # refresh this laptop's IP in the firewall
caytu-client -t gcp-single gcp instance info
caytu-client -t gcp-single gcp instance stop     # pauses billing for compute (disk + IP still cost)
caytu-client -t gcp-single gcp instance start
caytu-client -t gcp-single gcp instance resize n2-standard-8
```

## Monitoring and backups

Identical to remote-ssh / on-prem — see [monitoring.md](monitoring.md) and [backup-restore.md](backup-restore.md). The Terraform-created GCS bucket is already wired into `.env.gcp-single` as `RESTIC_REPOSITORY`. Set a strong `RESTIC_PASSWORD` then:

```bash
caytu-client -t gcp-single backup enable
```

The VM's service account has `storage.objectAdmin` on the backup bucket — no keys needed.

## Costs (us-central1, rough)

- e2-standard-4: ~$100/mo
- 100 GB pd-balanced: ~$10/mo
- Static IP: ~$3/mo
- Artifact Registry: ~$0.10/GB
- GCS backups: ~$0.020/GB Standard, ~$0.0012/GB Archive after 90d

**Baseline: ~$115-130/mo.**

## Why no managed messaging on GCP

GCP retired IoT Core in 2023 and has no drop-in replacement. There is no GCP-managed equivalent to KVS WebRTC. Options if you want managed:

- **LiveKit Cloud** for WebRTC signaling + SFU
- **EMQX Cloud** or **HiveMQ Cloud** for MQTT
- Point the app at their endpoints via `.env.<>`; disable the in-stack services by setting `COMPOSE_PROFILES=` in `.env.gcp-single`

For most GCP deployments the self-hosted defaults are simpler and cheaper.

## Tearing down

```bash
caytu-client -t gcp-single gcp destroy
```

GCS bucket with versioning enabled won't destroy while it has objects. Empty first (`gcloud storage rm -r gs://<bucket>/**`) or set `force_destroy = true` in the bucket resource before running destroy.
