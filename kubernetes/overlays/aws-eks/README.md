# AWS EKS overlay

Kustomize overlay for the `aws-cluster` target.

## What changes vs the base

- **Removed:** `signaling-server`, `coturn`, `coturn-config` — replaced by AWS KVS WebRTC signaling and its built-in ICE server.
- **Storage class:** `gp3` (via the AWS EBS CSI driver — an EKS addon).
- **Ingress class:** `alb` (via AWS Load Balancer Controller). ACM certificate ARN goes in the ingress annotation.
- **Backend + gstreamer:** `STREAMING_PROVIDER=kvs` forced via env patch.

## Prerequisites

1. **Provision the cluster** with the Terraform in [`terraform/aws/managed-cluster/`](../../../terraform/aws/managed-cluster/). It outputs `helm_commands` — run them to install:
   - AWS Load Balancer Controller (creates ALBs from Ingress resources)
   - EBS CSI driver (provisions gp3 PVs)
   - metrics-server (for `kubectl top` and HPA)

2. **Bring an ACM cert** for your domain (in the same region as the cluster). Get its ARN.

3. **Push images to ECR** at the URIs `terraform output ecr_repository_uris` prints.

## First run

```bash
cd kubernetes/overlays/aws-eks
cp secrets.env.example secrets.env
$EDITOR secrets.env  # fill in DB creds, LLM keys, AWS_IOT_ENDPOINT, AWS_IOT_ROLE_ALIAS

$EDITOR kustomization.yaml
# - update `images:` newName with your ECR account/region, and newTag
# - update the ingress patch's host and alb.ingress.kubernetes.io/certificate-arn

kubectl config use-context <your eks context>
caytu-client -t aws-cluster k8s doctor
caytu-client -t aws-cluster k8s diff
caytu-client -t aws-cluster k8s apply
```

## IRSA (recommended for prod)

Rather than baking AWS credentials into `secrets.env`, use IAM Roles for Service Accounts. Terraform creates a role you can bind to a service account:

```bash
# Terraform output: irsa_backend_role_arn = "arn:aws:iam::...:role/caytu-client-backend"

kubectl -n caytu-client annotate serviceaccount backend \
  eks.amazonaws.com/role-arn=arn:aws:iam::...:role/caytu-client-backend
```

Then remove the AWS_* keys from `secrets.env`. Same pattern for `gstreamer-recorder` and `mqtt-streamer` if they need direct AWS credentials.

## Costs (us-east-1, rough)

- EKS control plane: $73/mo flat
- 2× t3.medium worker nodes: ~$60/mo
- ALB: ~$18/mo + traffic
- gp3 PVs (~200 GB total): ~$16/mo
- ECR: ~$5-10/mo per repo family
- KVS signaling: per-minute of active sessions
- IoT Core: per million messages

**Baseline: ~$180-220/mo** for a small production cluster; scales with node count.

## Removal

```bash
caytu-client -t aws-cluster k8s delete
# then in terraform/aws/managed-cluster:
terraform destroy
```

Order matters: `k8s delete` first so the LoadBalancer + EBS volumes it created get cleaned up before Terraform tears down the cluster (otherwise you'll orphan them).
