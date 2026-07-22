# AWS single-instance Terraform

What this creates in one `terraform apply`:

- **Networking:** uses your account's default VPC by default (override via `vpc_id`/`subnet_id`), plus a security group opening 22/80/443 (+ TURN ports if `enable_turn_ports = true`)
- **Compute:** one EC2 instance (`r6g.large` default, Graviton/arm64) with an Elastic IP, IMDSv2 required, GP3 root volume, cloud-init runs [`scripts/bootstrap.sh`](../../../scripts/bootstrap.sh) at first boot
- **IAM:** instance profile with permissions for ECR pull, KVS signaling, IoT data plane, S3 backup bucket, SSM Session Manager
- **Registry:** ECR repositories for `backend`, `frontend`, `webrtc-signaling`, `gstreamer-recorder`, `mqtt-streamer` — with lifecycle policy (30 tagged, 7d untagged)
- **Backups:** S3 bucket with versioning + SSE + public access block + optional lifecycle to Glacier
- **IoT device auth:** IoT policy for device certs + IAM role + IoT role alias for KVS credential vending

You normally don't run terraform by hand — [`caytu-client aws provision`](../../../scripts/caytu-client) drives this whole flow and writes the outputs into `.caytu-client-state.json` + `compose/.env.aws-single`.

## Manual usage

```bash
cd terraform/aws/single-instance
cp example.tfvars terraform.tfvars
$EDITOR terraform.tfvars

terraform init
terraform plan
terraform apply
terraform output -json > outputs.json
```

Outputs consumed downstream:

| Output | Where it lands |
|---|---|
| `public_ip` | `.caytu-client-state.json` → `ssh_host` |
| `key_name`, `ssh_key_path` | `.caytu-client-state.json` → `ssh_key_path` |
| `security_group_id` | `.caytu-client-state.json` → `security_group_id` (used by `aws allow-me`) |
| `ecr_registry` | `.env.aws-single` → `IMAGE_REGISTRY` |
| `restic_repository` | `.env.aws-single` → `RESTIC_REPOSITORY` |
| `iot_data_endpoint` | `.env.aws-single` → `AWS_IOT_ENDPOINT` |
| `iot_role_alias` | `.env.aws-single` → `AWS_IOT_ROLE_ALIAS` |

## Remote state (recommended for prod)

The default backend is local (`terraform.tfstate` next to the config). For anything you care about, uncomment the `backend "s3"` block in [`versions.tf`](versions.tf) and create the bucket + DynamoDB table first:

```bash
aws s3api create-bucket --bucket caytu-client-tf-state --region us-east-1
aws s3api put-bucket-versioning --bucket caytu-client-tf-state --versioning-configuration Status=Enabled
aws dynamodb create-table --table-name caytu-client-tf-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
terraform init -migrate-state
```

## Costs (us-east-1, rough)

- r6g.large:  ~$60/mo
- 100 GB gp3: ~$8/mo
- Elastic IP (attached): free; unattached: ~$3.60/mo
- S3 backups: ~$0.023/GB/mo (Standard) → ~$0.004/GB/mo (Glacier)
- ECR: first 500 MB free, then ~$0.10/GB/mo
- IoT + KVS: per-message and per-minute pricing, usually a few dollars for staging

Baseline: **~$70-80/mo** for a lightly used staging box; scale up the instance type for prod.

## Tearing down

```bash
caytu-client -t aws-single destroy
# or, manually:
cd terraform/aws/single-instance && terraform destroy
```

`terraform destroy` will refuse to nuke a non-empty S3 backup bucket. Empty it first (`aws s3 rm --recursive`) or `terraform state rm aws_s3_bucket.backups[0]` to leave the bucket in place.
