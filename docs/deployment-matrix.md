# Deployment matrix

Six targets, one CLI (`caytu-client --target <target>`). Pick the one that fits your operational constraints.

## Single-instance (Docker Compose)

Everything runs on one host. Good enough for pilots, staging, small production, air-gapped sites. Recovery is a fresh VM + restore from backup.

| Target | Provisioning | Where | Cost floor | Notes |
|---|---|---|---|---|
| `local` | none | laptop | free | dev with bind mounts + hot reload |
| `onprem` | operator owns the host | on-site server, LAN | hardware only | prod stack, TLS via self-signed or BYO cert (no public DNS needed) |
| `ssh` | operator brings the host | anywhere with public DNS | varies | any distro Docker runs on, Let's Encrypt |
| `aws-single` | Terraform (EC2, EIP, SG, ECR, S3, IoT role alias) | AWS | ~$70-90/mo (r6g.large) | Managed defaults: AWS IoT Core + KVS |
| `gcp-single` | Terraform (GCE, static IP, firewall, Artifact Registry, GCS) | GCP | ~$115-130/mo (e2-standard-4) | Self-hosted messaging (no managed GCP path) |

`local` uses `docker-compose.yml` + `docker-compose.local.yml`. The other four all use `docker-compose.yml` + `docker-compose.remote.yml`; they differ only in how the host is provisioned and how TLS is issued.

## Managed cluster (Kubernetes)

Everything runs across N nodes with autoscaling, rolling updates, replicated storage. Bigger blast radius when misconfigured, higher fixed cost, richer HA story.

| Target | Provisioning | Where | Cost floor | Notes |
|---|---|---|---|---|
| `aws-cluster` (phase 4) | Terraform (EKS, ECR, VPC, IAM) | AWS | ~$400/mo (EKS control + 2×t3.medium) | Mongo StatefulSet or Atlas overlay |
| `gcp-cluster` (phase 4) | Terraform (GKE, Artifact Registry, VPC) | GCP | ~$300/mo (GKE Autopilot) | Mongo StatefulSet or Atlas overlay |
| `self-managed-k8s` (phase 4) | `bootstrap.sh --install-k3s` OR BYO kubeconfig | operator's nodes | hardware only | nginx-ingress + local-path storage default; on-prem HA path |

All three consume the same Kustomize base under `kubernetes/base/`; overlays under `kubernetes/overlays/{aws-eks,gcp-gke,self-managed}` add storage classes, ingress class, and cloud-specific tweaks. The self-managed overlay assumes nginx-ingress + a configurable storage class (defaults to `local-path`, so k3s works out of the box).

## Data plane choice

| Component | Single-instance | Cluster |
|---|---|---|
| MongoDB 8.2 | container in stack, replica-set-of-one | 3-pod StatefulSet on EBS/PD; `--profile search` for vector search |
| Redis 7 | container in stack | Deployment + PVC |
| MinIO | container in stack | Deployment + PVC (or optional s3/gcs backend swap) |
| Object storage backup | restic → S3/GCS/B2/SFTP | same |

For managed Mongo (Atlas) instead of self-hosted, use the `atlas` overlay (added in phase 4/5).

## When to pick which

- **Developing** → `local`
- **Customer site, private LAN, no public DNS** → `onprem`
- **Public-internet single server with a domain** → `ssh` (or `aws-single`/`gcp-single` if you want Terraform-managed provisioning)
- **Multiple tenants on one box** → `ssh` or single-instance cloud, size up
- **Multiple boxes, HA, no room for downtime on a single-VM restore** → cluster (`aws-cluster`, `gcp-cluster`, or `self-managed-k8s`)
- **On-prem, HA required (multiple boxes, no cloud)** → `self-managed-k8s` with k3s
- **Air-gapped, single box** → `onprem` with `docker load`-ed images, `ssl self-signed`, SFTP restic target
- **Air-gapped, HA** → `self-managed-k8s` with k3s on multiple nodes, private registry, SFTP restic
