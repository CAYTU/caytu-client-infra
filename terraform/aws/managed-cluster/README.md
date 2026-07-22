# AWS EKS Terraform

Provisions a production-shaped EKS cluster for the `aws-cluster` target.

What lands after `terraform apply`:

- **VPC** — 3 AZs, public + private subnets, single NAT (staging cost mode), subnet tags for ALB discovery
- **EKS cluster** — Kubernetes 1.30, public endpoint, managed node group (t3.medium × 2 on-demand, autoscales to 5), cluster addons: coredns, kube-proxy, vpc-cni, aws-ebs-csi-driver
- **Storage class `gp3`** — default, replaces gp2 which is un-defaulted
- **IAM/IRSA roles:**
  - `ebs-csi` (for the EBS CSI addon)
  - `alb-controller` (for aws-load-balancer-controller — install via helm, see outputs)
  - `backend` (bind to the backend ServiceAccount for KVS + IoT access without static creds)
  - `backup` (bind to a CronJob ServiceAccount named `backup` for S3 write access)
- **ECR repos** — backend, frontend, gstreamer-recorder, mqtt-streamer (no webrtc-signaling — KVS replaces it)
- **IoT device auth** — policy + role alias for KVS credential vending (same as single-instance)
- **S3 backup bucket** — versioned, encrypted, IRSA-bound for a future backup CronJob

## Post-apply steps

The `helm_commands` output prints exactly what to run — copy/paste. Summary:

```bash
$(terraform output -raw kubeconfig_command)

# ALB controller (Terraform outputs the exact command with your role ARN filled in)
helm install aws-load-balancer-controller eks/aws-load-balancer-controller ...

# metrics-server
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# App
cd ../../../kubernetes/overlays/aws-eks
cp secrets.env.example secrets.env && $EDITOR secrets.env
$EDITOR kustomization.yaml   # <ACCOUNT>, <REGION>, ACM cert ARN, hostname
caytu-client -t aws-cluster k8s apply
```

## Manual usage

```bash
cd terraform/aws/managed-cluster
cp example.tfvars terraform.tfvars
$EDITOR terraform.tfvars   # set region, operator_ssh_cidrs, operator_admin_arns

terraform init
terraform plan
terraform apply
terraform output -json
```

## Cost (us-east-1, rough)

- EKS control plane: $73/mo flat
- 2× t3.medium: ~$60/mo (on-demand), ~$18/mo (SPOT)
- NAT gateway (single): ~$32/mo + traffic
- ALB (created by ingress): ~$18/mo + LCU
- EBS gp3 (~200 GB): ~$16/mo
- ECR: minimal
- KVS + IoT: per-use

**Baseline: ~$200/mo staging** with single NAT; add ~$60/mo for 3-NAT HA prod.

## Destroy order

The overlay creates AWS resources (ALB, EBS volumes) via k8s controllers. Delete those first, then Terraform:

```bash
caytu-client -t aws-cluster k8s delete
terraform destroy
```

Skipping `k8s delete` orphans the ALB + volumes; you'll clean them up manually and re-run destroy.
