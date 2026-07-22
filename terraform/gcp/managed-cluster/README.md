# GCP GKE Terraform

Provisions a GKE Standard cluster for the `gcp-cluster` target.

What lands after `terraform apply`:

- **VPC** — custom-mode network + subnet with secondary ranges for pods/services (VPC-native / alias IP)
- **Cloud NAT** — private nodes reach the internet (Artifact Registry, apt, etc.)
- **GKE cluster** — Kubernetes 1.30, REGULAR release channel, Workload Identity enabled, GCE PD CSI enabled, HPA + HTTP LB addons
- **Node pool** — 3× e2-standard-2 by default, autoscales to 10, auto-repair + auto-upgrade
- **Workload Identity bindings** — GSAs for `backend` and `backup` k8s ServiceAccounts
- **Global static IP** — named `caytu-client-ingress`, referenced by the GCE Ingress
- **Artifact Registry** — 5 Docker repos with cleanup policies
- **GCS backup bucket** — versioned, lifecycle to Archive at 90d

## First run

```bash
cd terraform/gcp/managed-cluster
cp example.tfvars terraform.tfvars
$EDITOR terraform.tfvars   # project_id at minimum

gcloud auth login
gcloud auth application-default login
gcloud config set project <YOUR_PROJECT>

terraform init
terraform apply    # ~10-15 min

$(terraform output -raw kubeconfig_command)
kubectl get nodes  # sanity check

# terraform output next_steps prints the rest
```

## Cost (us-central1, rough)

- Zonal cluster: no management fee for the control plane (regional is $73/mo)
- 3× e2-standard-2: ~$150/mo (on-demand), ~$50/mo (preemptible)
- Cloud NAT: ~$32/mo + traffic
- HTTP(S) Load Balancer: ~$20/mo + forwarding rules
- Persistent Disks (~200 GB): ~$20/mo
- Artifact Registry + GCS: minimal

**Baseline: ~$225/mo zonal, ~$300+ regional** (adds ~$75 for the control plane + more node redundancy).

## Destroy order

```bash
caytu-client -t gcp-cluster k8s delete   # release the LB + PDs first
terraform destroy
```

`google_container_cluster.deletion_protection` is `false` in this config; flip to `true` for prod.
