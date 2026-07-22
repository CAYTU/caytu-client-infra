# GCP GKE overlay

Kustomize overlay for the `gcp-cluster` target.

## What changes vs the base

- **Kept:** signaling-server, coturn, all in-stack messaging — GCP has no managed KVS / IoT Core.
- **Storage class:** `standard-rwo` (balanced PD) for mongo/redis/gstreamer, `premium-rwo` (SSD PD) for MinIO.
- **Ingress class:** `gce` — creates a Google Cloud HTTP(S) Load Balancer. Uses a `ManagedCertificate` for TLS (auto-provisions via LE once DNS resolves).
- **coturn Service type:** `LoadBalancer` — GKE supports UDP LB natively, so the ephemeral UDP range is reachable without `hostNetwork`.

## Prerequisites

1. **Provision the cluster** with [`terraform/gcp/managed-cluster/`](../../../terraform/gcp/managed-cluster/). It creates:
   - VPC + GKE cluster
   - Global static IP named `caytu-client-ingress`
   - Artifact Registry repos
   - GCS backup bucket
   - Workload Identity binding for the backend + backup service accounts

2. **DNS:** create an A record pointing your domain at the static IP (`terraform output ingress_ip`).

3. **Push images** to Artifact Registry.

## First run

```bash
cd kubernetes/overlays/gcp-gke
cp secrets.env.example secrets.env
$EDITOR secrets.env

$EDITOR kustomization.yaml    # <REGION>, <PROJECT>, images tag, hostname
$EDITOR managed-cert.yaml     # domain(s)

gcloud container clusters get-credentials <cluster> --region <region> --project <project>
caytu-client -t gcp-cluster k8s doctor
caytu-client -t gcp-cluster k8s diff
caytu-client -t gcp-cluster k8s apply
```

TLS: the `ManagedCertificate` takes 15-60 minutes to provision after DNS points at the static IP. Check with `kubectl -n caytu-client describe managedcertificate caytu-cert`.

## Workload Identity (recommended for prod)

Terraform creates GSAs bound to Kubernetes ServiceAccounts. Bind them:

```bash
# From `terraform output`:
kubectl -n caytu-client annotate serviceaccount backend \
  iam.gke.io/gcp-service-account=caytu-client-backend@<project>.iam.gserviceaccount.com
```

Backend pods now assume that GSA — no static credentials needed for GCS / Cloud SQL / other GCP APIs.

## Costs (us-central1, rough)

- GKE Standard (management fee for zonal cluster: free; regional: ~$73/mo)
- 3× e2-standard-2 workers: ~$150/mo
- HTTP(S) LB: ~$20/mo + forwarding rules
- Persistent Disks (~200 GB total): ~$20/mo
- Artifact Registry: minimal

**Baseline: ~$200-250/mo** for a zonal cluster; ~$300+ for a regional cluster.

## Removing

```bash
caytu-client -t gcp-cluster k8s delete
cd ../../../terraform/gcp/managed-cluster && terraform destroy
```

`k8s delete` first so the LB + PDs get cleaned up by GKE before Terraform tears down the cluster.
