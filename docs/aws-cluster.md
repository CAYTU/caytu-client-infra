# AWS EKS deployment

Production-shape HA on AWS. Automatic AWS-managed messaging (IoT Core + KVS), self-hosted MongoDB StatefulSet (with the Atlas overlay as an opt-in when phase 4 finalizes), gp3 EBS storage, ALB ingress with ACM TLS, IRSA-scoped IAM per service.

## Prerequisites

- AWS CLI v2 authenticated (SSO / static keys / assume-role)
- Terraform ≥ 1.6
- `kubectl` ≥ 1.28, `helm` ≥ 3.14, `jq`
- One ACM certificate in the target region for your app hostname (Terraform doesn't provision it — you'd typically already have DNS + ACM set up)

## First run

```bash
# 1. Provision the cluster
cd terraform/aws/managed-cluster
cp example.tfvars terraform.tfvars
$EDITOR terraform.tfvars

terraform init
terraform apply    # ~15-20 min for EKS
$(terraform output -raw kubeconfig_command)   # add cluster to your kubeconfig

# 2. Cluster prereqs (helm) — Terraform outputs the exact commands
terraform output helm_commands
# ... run the printed helm install for aws-load-balancer-controller
# ... apply metrics-server
kubectl get pods -n kube-system   # confirm all Running

# 3. Push images to ECR
terraform output ecr_repository_uris
aws ecr get-login-password --region <region> | \
  docker login --username AWS --password-stdin <account>.dkr.ecr.<region>.amazonaws.com
docker tag caytu-client-backend:local <account>.dkr.ecr.<region>.amazonaws.com/caytu-client-backend:<tag>
docker push <account>.dkr.ecr.<region>.amazonaws.com/caytu-client-backend:<tag>
# ... etc

# 4. Configure and deploy the app
cd ../../../kubernetes/overlays/aws-eks
cp secrets.env.example secrets.env
$EDITOR secrets.env
# Copy these from `terraform output`:
#   AWS_IOT_ENDPOINT=$(terraform -chdir=../../../terraform/aws/managed-cluster output -raw iot_data_endpoint)
#   AWS_IOT_ROLE_ALIAS=$(terraform -chdir=../../../terraform/aws/managed-cluster output -raw iot_role_alias)

$EDITOR kustomization.yaml
# - replace <ACCOUNT>, <REGION> in images:
# - set newTag: to your pushed tag
# - set the ingress host: to your hostname
# - set alb.ingress.kubernetes.io/certificate-arn to your ACM cert ARN

caytu-client -t aws-cluster k8s doctor
caytu-client -t aws-cluster k8s diff
caytu-client -t aws-cluster k8s apply
caytu-client -t aws-cluster k8s status

# 5. Bind IRSA roles to service accounts (skip static AWS creds in secrets.env)
terraform -chdir=terraform/aws/managed-cluster output irsa_backend_role_arn
kubectl -n caytu-client annotate serviceaccount backend \
  eks.amazonaws.com/role-arn=arn:aws:iam::...:role/caytu-client-staging-backend

# 6. DNS: point your hostname at the ALB
kubectl -n caytu-client get ingress caytu-client -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
# Create a CNAME or Route 53 alias from your hostname → that ALB DNS
```

## Everyday verbs

```bash
caytu-client -t aws-cluster k8s status
caytu-client -t aws-cluster k8s logs backend
caytu-client -t aws-cluster k8s scale backend 4
caytu-client -t aws-cluster k8s rollout status backend
caytu-client -t aws-cluster k8s rollout restart backend
caytu-client -t aws-cluster k8s exec backend
```

**Deploying a new image tag:** update `newTag` in the overlay's `kustomization.yaml` and `k8s apply`. Kustomize + kubectl handle the rolling update.

## What's NOT in the cluster (managed defaults)

- `signaling-server` — deleted by the overlay. WebRTC signaling goes through KVS.
- `coturn` — deleted by the overlay. KVS `GetIceServerConfig` provides ICE servers.
- `mosquitto` — never in the base. Devices publish to AWS IoT Core; `mqtt-streamer` subscribes there.

If you need to override any of this (e.g. temporarily run self-hosted signaling), copy `kubernetes/overlays/aws-eks/` to a new overlay dir and remove the `$patch: delete` blocks.

## MongoDB HA

Base ships as a 1-replica StatefulSet. For real HA:

**Option A — 3-replica StatefulSet on EBS.** Patch `replicas: 3` in the overlay and initialize the replica set manually. Fine for staging.

**Option B — MongoDB Community Kubernetes Operator.** Better for prod. Add its CRDs, replace the StatefulSet with a `MongoDBCommunity` resource. Not shipped in this overlay.

**Option C — MongoDB Atlas.** Managed. Point `MONGO_URI` in secrets.env at the Atlas cluster and delete the local mongodb StatefulSet via a patch. Atlas overlay lands with phase 4 finalization.

## Backups

Recommended path: a `CronJob` in the cluster that runs `mongodump` and uploads via `aws s3 cp` using the IRSA role Terraform created (`irsa_backup_role_arn`). Not shipped as a manifest — add via:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata: { name: mongo-backup, namespace: caytu-client }
spec:
  schedule: "0 2 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: backup
          restartPolicy: OnFailure
          containers:
            - name: mongodump
              image: mongo:8.2
              command: [sh, -c, "mongodump --uri $MONGO_URI --gzip --archive | aws s3 cp - s3://$BUCKET/mongo-$(date -u +%FT%TZ).gz"]
              env:
                - { name: MONGO_URI, valueFrom: { secretKeyRef: { name: caytu-secrets, key: MONGO_URI } } }
                - { name: BUCKET, value: "<from terraform output backup_bucket>" }
```

Then annotate the `backup` ServiceAccount with `eks.amazonaws.com/role-arn=<irsa_backup_role_arn>`.

## Removing

```bash
caytu-client -t aws-cluster k8s delete
terraform -chdir=terraform/aws/managed-cluster destroy
```

Order matters — `k8s delete` first so the ALB and EBS volumes get cleaned up by their controllers before the cluster goes away.

## Costs (us-east-1, rough)

- EKS control plane: $73/mo flat
- 2× t3.medium worker nodes: ~$60/mo (on-demand) or ~$18/mo (SPOT)
- NAT gateway: ~$32/mo + traffic
- ALB: ~$18/mo + LCU
- EBS gp3 (~200 GB total): ~$16/mo
- ECR + IoT + KVS: per-use, usually a few dollars for staging

**Baseline: ~$200-250/mo** for staging, ~$400+ for HA prod.
