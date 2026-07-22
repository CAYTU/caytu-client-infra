# GCP single-instance Terraform

What this creates in one `terraform apply`:

- **Enabled services:** compute, artifactregistry, iam, iamcredentials, storage, logging, monitoring
- **Compute:** one GCE VM (`e2-standard-4` default, x86_64) with a static external IP, shielded VM, Ubuntu 24.04 LTS, startup-script runs [`scripts/bootstrap.sh`](../../../scripts/bootstrap.sh)
- **Firewall:** 22 (restricted to `operator_ssh_cidrs`), 80/443, TURN ports (3478/5349/49152-49252) when `enable_turn_ports = true`
- **Service account:** attached to the VM with `artifactregistry.reader`, `logging.logWriter`, `monitoring.metricWriter`, and `storage.objectAdmin` on the backup bucket
- **Registry:** Artifact Registry Docker repos for the 5 service images, with cleanup policy (30 tagged, 7d untagged)
- **Backups:** GCS bucket with versioning + lifecycle to Archive at 90d

Driven end-to-end by [`caytu-client gcp provision`](../../../scripts/caytu-client).

## Manual usage

```bash
cd terraform/gcp/single-instance
cp example.tfvars terraform.tfvars
$EDITOR terraform.tfvars   # at minimum: project_id, operator_ssh_cidrs

gcloud auth application-default login   # or set GOOGLE_APPLICATION_CREDENTIALS

terraform init
terraform plan
terraform apply
terraform output -json > outputs.json
```

Outputs consumed downstream:

| Output | Where it lands |
|---|---|
| `public_ip` | `.caytu-client-state.json` → `ssh_host` |
| `ssh_key_path`, `ssh_user` | `.caytu-client-state.json` |
| `image_registry` | `.env.gcp-single` → `IMAGE_REGISTRY` |
| `restic_repository` | `.env.gcp-single` → `RESTIC_REPOSITORY` |
| `region` | `.env.gcp-single` |

## Costs (us-central1, rough)

- e2-standard-4: ~$100/mo
- 100 GB pd-balanced: ~$10/mo
- Static IP (attached): ~$3/mo
- GCS Standard: ~$0.020/GB/mo; Archive: ~$0.0012/GB/mo
- Artifact Registry: first 500 MB free, then ~$0.10/GB/mo
- Egress: variable

Baseline: **~$115-130/mo** for a lightly used staging box.

## Notes vs the AWS module

- **No managed messaging:** GCP has no equivalent to AWS IoT Core (retired 2023) or KVS. Self-hosted signaling-server + coturn run on the instance (see [cloud-defaults.md](../../../docs/cloud-defaults.md)). If you need managed, either bring 3rd-party services (LiveKit Cloud, EMQX Cloud) or move to the `gcp-cluster` target (phase 4) and self-host at scale.
- **Auth:** Artifact Registry pulls use the attached service account — no `docker login` needed on the box.
- **OS Login is disabled** in favour of metadata SSH keys, matching the AWS module's ergonomics. Flip via `metadata.enable-oslogin` if your org requires it.
