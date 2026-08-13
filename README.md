# caytu-client-infra

Deployment infrastructure for the [`caytu-client`](https://github.com/CAYTU/caytu-client) platform.

One repo, one CLI, six deployment targets:

| Target | Provisioning | Orchestration | Where you run it |
|---|---|---|---|
| `local` | none | docker compose | your laptop (dev, hot reload) |
| `onprem` | operator owns the host | docker compose | on-site server on a LAN (self-signed / BYO cert) |
| `ssh` | operator-managed | docker compose | any Linux host with public DNS (Let's Encrypt) |
| `aws-single` | Terraform: EC2 + EIP + SG + ECR + S3 + IoT | docker compose | one AWS EC2 instance |
| `gcp-single` | Terraform: GCE + static IP + Artifact Registry + GCS | docker compose | one GCP Compute Engine VM |
| `aws-cluster` | Terraform: EKS + ECR + VPC + IRSA | kubernetes (kustomize) | AWS EKS |
| `gcp-cluster` | Terraform: GKE + Artifact Registry + Workload Identity | kubernetes (kustomize) | GCP GKE |
| `self-managed-k8s` | k3s installer or BYO kubeconfig | kubernetes (kustomize) | operator's own nodes (bare-metal, on-prem VMs, any cloud) |

All 8 targets shipped: the compose stack + monitoring + backup + CLI cover local/onprem/ssh/aws-single/gcp-single; the Kustomize base + three cloud overlays cover the cluster tiers.

## Repo layout

```
compose/                  base + overlay docker-compose files, nginx, monitoring, backup
kubernetes/               kustomize base + per-cluster overlays  (phases 4-5)
terraform/                aws/ and gcp/ modules                   (phases 2-5)
scripts/
  caytu-client            main CLI (bash)
  bootstrap.sh            one-shot Ubuntu host bootstrap
  lib/                    shared helpers
docs/                     per-target guides
```

## Quick start

**Local dev:**
```bash
git clone https://github.com/CAYTU/caytu-client-infra
cd caytu-client-infra
./scripts/caytu-client install     # symlink into ~/.local/bin
caytu-client --target local init   # writes compose/.env.local
# edit compose/.env.local
caytu-client --target local up --build
```

**Remote SSH host (fresh Ubuntu box, public DNS):**
```bash
# on the target host, once:
curl -fsSL https://raw.githubusercontent.com/CAYTU/caytu-client-infra/main/scripts/bootstrap.sh | sudo bash

# from your workstation:
caytu-client -t ssh state set ssh_host <ip>
caytu-client -t ssh state set ssh_user ubuntu
caytu-client -t ssh state set ssh_key_path ~/.ssh/id_ed25519
caytu-client -t ssh init
# edit compose/.env.ssh (set IMAGE_REGISTRY, IMAGE_TAG, MINIO creds, TURN secret, CAYTU_DOMAIN)
caytu-client -t ssh env push
caytu-client -t ssh up
caytu-client -t ssh ssl bootstrap yourdomain.com ops@yourdomain.com
```

**On-premise (private LAN, fixed IP, no public DNS):**
```bash
# on the on-prem host:
sudo bash scripts/bootstrap.sh
./scripts/caytu-client install
caytu-client -t onprem init            # creates compose/.env.onprem
# edit compose/.env.onprem — set CAYTU_DOMAIN to the IP (e.g. 10.0.1.42)
caytu-client -t onprem up
caytu-client -t onprem ssl self-signed 10.0.1.42   # or: ssl http-only / ssl bring-your-own
```

## Docs

- [Architecture](docs/architecture.md) - what the pieces are and who talks to whom
- [Deployment matrix](docs/deployment-matrix.md) — which target for which use case
- [Local development](docs/local-development.md)
- [On-premise deployment](docs/on-premise.md)
- [Remote SSH deployment](docs/remote-ssh.md)
- [AWS single-instance](docs/aws-single-instance.md) — Terraform-provisioned EC2 + IoT + KVS
- [GCP single-instance](docs/gcp-single-instance.md) — Terraform-provisioned GCE + Artifact Registry
- [Self-managed Kubernetes](docs/self-managed-k8s.md) — k3s or any BYO kubeconfig
- [AWS EKS](docs/aws-cluster.md) — Terraform-provisioned EKS + ALB + IRSA + IoT/KVS
- [GCP GKE](docs/gcp-cluster.md) — Terraform-provisioned GKE + GCE Ingress + Workload Identity
- [Cluster performance & load balancing](docs/cluster-performance.md) — HPA, PDB, session affinity, MetalLB, per-cloud LB tuning
- [Cloud defaults](docs/cloud-defaults.md) — self-hosted vs AWS-managed messaging
- [Monitoring](docs/monitoring.md)
- [Backup & restore](docs/backup-restore.md)
- [Secrets](docs/secrets.md)

## Design notes

**Compose files are layered, not duplicated.** `docker-compose.yml` is the single source of truth for what services exist. Overlays only add environment-specific bits (build contexts for local, nginx+certbot for remote, etc.). This replaces the caytu-client repo's four partially-overlapping compose files.

**Deployment state lives in `.caytu-client-state.json`** next to the CLI. It tracks the SSH host, key path, and per-target toggles (monitoring on/off, backup on/off). Gitignored — one state file per operator laptop.

**Secrets never sit in Terraform state or the compose file.** They live in `compose/.env.*` (gitignored) and get rsynced to remote hosts by `caytu-client env push`.
