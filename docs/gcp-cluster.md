# GCP GKE deployment

Production-shape HA on GCP. Self-hosted messaging (signaling-server + coturn + MQTT — GCP has no managed KVS/IoT Core equivalent), MongoDB StatefulSet, `standard-rwo` / `premium-rwo` persistent disks, GCE HTTP(S) Load Balancer with Google-managed TLS, Workload Identity for scoped IAM per service.

## Prerequisites

- `gcloud` authenticated: `gcloud auth login && gcloud auth application-default login`
- Terraform ≥ 1.6
- `kubectl` ≥ 1.28, `jq`
- A domain you control (Google-managed cert needs DNS resolution to provision)

## First run

```bash
# 1. Provision the cluster
cd terraform/gcp/managed-cluster
cp example.tfvars terraform.tfvars
$EDITOR terraform.tfvars   # project_id, region, zone/regional

terraform init
terraform apply   # ~10-15 min

$(terraform output -raw kubeconfig_command)
terraform output next_steps

# 2. Push images to Artifact Registry
terraform output artifact_repository_uris
gcloud auth configure-docker $(terraform output -raw image_registry | cut -d/ -f1) --quiet
docker tag caytu-client-backend:local $(terraform output -json artifact_repository_uris | jq -r .backend):<tag>
docker push $(terraform output -json artifact_repository_uris | jq -r .backend):<tag>
# ... repeat for the other 4 services

# 3. Point DNS at the ingress static IP
terraform output ingress_ip
# Create an A record: caytu.example.com → <ingress_ip>

# 4. Configure the overlay
cd ../../../kubernetes/overlays/gcp-gke
cp secrets.env.example secrets.env
$EDITOR secrets.env

$EDITOR kustomization.yaml
# - replace <PROJECT>, <REGION> in images:
# - set newTag: to your pushed tag
# - set the ingress rule host: to your hostname

$EDITOR managed-cert.yaml   # domain

# 5. Deploy
caytu-client -t gcp-cluster k8s doctor
caytu-client -t gcp-cluster k8s diff
caytu-client -t gcp-cluster k8s apply
caytu-client -t gcp-cluster k8s status

# 6. Wait for the managed cert to provision (up to 60 min)
kubectl -n caytu-client describe managedcertificate caytu-cert
# status Provisioning → Active means it's ready
```

## Workload Identity (recommended)

```bash
kubectl -n caytu-client annotate serviceaccount backend \
  iam.gke.io/gcp-service-account=caytu-client-<env>-backend@<project>.iam.gserviceaccount.com

kubectl -n caytu-client annotate serviceaccount backup \
  iam.gke.io/gcp-service-account=caytu-client-<env>-backup@<project>.iam.gserviceaccount.com
```

The backend pod now assumes the backend GSA; the backup CronJob's pod assumes the backup GSA (which has `storage.objectAdmin` on the backup bucket). No static credentials in `secrets.env`.

## Backups

Same pattern as [aws-cluster.md](aws-cluster.md) — deploy a CronJob that runs `mongodump | gcloud storage cp -` using the Workload Identity-bound `backup` ServiceAccount. Not shipped in the overlay; add via a patch or a separate file.

## MongoDB HA

Same options as AWS:

- **3-replica StatefulSet** on premium-rwo (SSD PD).
- **MongoDB Community Operator** — better ergonomics for prod.
- **MongoDB Atlas** — managed. Available on GCP Marketplace, billing flows through your GCP invoice. Point `MONGO_URI` at the Atlas endpoint and delete the local StatefulSet via patch.

## TLS

The overlay ships `ManagedCertificate` (a GKE-specific CRD). Google provisions the LE cert automatically once the domain resolves to the static IP. No cert-manager needed.

Alternative: skip the ManagedCertificate, install cert-manager, and use standard `Certificate` CRDs. Same TLS story as [self-managed-k8s.md](self-managed-k8s.md).

## Removing

```bash
caytu-client -t gcp-cluster k8s delete
cd terraform/gcp/managed-cluster && terraform destroy
```

## Costs (us-central1, rough)

- Zonal control plane: free; Regional: ~$73/mo
- 3× e2-standard-2: ~$150/mo (on-demand), ~$50/mo (preemptible)
- Cloud NAT: ~$32/mo + traffic
- HTTP(S) LB: ~$20/mo
- Persistent Disks (~200 GB): ~$20/mo

**Baseline: ~$225/mo** zonal with on-demand nodes; drop ~$100/mo with preemptible for non-prod.
