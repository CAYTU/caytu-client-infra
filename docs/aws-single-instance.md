# AWS single-instance deployment

Full stack on one EC2 with everything Terraform-managed: instance, EIP, security group, ECR repos, S3 backup bucket, IoT device auth, IAM roles for KVS. Automatic AWS-managed messaging defaults (IoT Core for MQTT, KVS WebRTC for signaling — see [cloud-defaults.md](cloud-defaults.md)).

## Prerequisites on your workstation

- AWS CLI v2, authenticated (SSO, static keys, whatever — `aws sts get-caller-identity` must work)
- Terraform ≥ 1.6
- `jq`, `rsync`, `docker`
- The `caytu-client` CLI installed (`./scripts/caytu-client install`)

The IAM identity you use needs to create: EC2, EIP, security groups, key pairs, IAM roles/policies, ECR repositories, S3 buckets, IoT policies + role aliases. `AdministratorAccess` is the easy path; for principle-of-least-privilege scope down using the Terraform plan output.

## First run

```bash
git clone https://github.com/CAYTU/caytu-client-infra
cd caytu-client-infra
./scripts/caytu-client install

# Tell the CLI which target you're driving
caytu-client -t aws-single doctor      # sanity checks
caytu-client -t aws-single init        # writes compose/.env.aws-single from the template

# Provision the AWS side. Terraform copies example.tfvars → terraform.tfvars
# and opens $EDITOR — set operator_ssh_cidrs, environment name, instance type.
#
# Optionally set the DNS block to have Terraform create the A record and the
# CLI issue the TLS cert for you:
#   enable_route53    = true
#   route53_zone_name = "caytu.link"
#   domain_name       = "client.caytu.link"
#   letsencrypt_email = "ops@caytu.com"
caytu-client -t aws-single aws provision

# The CLI now knows:
#   ssh_host             = EIP
#   ssh_user             = ubuntu
#   ssh_key_path         = ./terraform/aws/single-instance/ssh_key.pem
#   security_group_id
#   instance_id
# And has patched compose/.env.aws-single with:
#   IMAGE_REGISTRY, AWS_REGION, RESTIC_REPOSITORY,
#   AWS_IOT_ENDPOINT, AWS_IOT_ROLE_ALIAS, STREAMING_PROVIDER=kvs

# Push image tags into ECR from your CI (see ../.github/workflows/*.yml) or
# manually push the images you want to run.
caytu-client -t aws-single aws ecr-login    # local docker login (also propagates to the host)
docker push <account>.dkr.ecr.<region>.amazonaws.com/caytu-client-backend:<tag>
# ... etc for frontend, webrtc-signaling, gstreamer-recorder, mqtt-streamer

# Fill in application config — one file for the whole deployment
$EDITOR compose/.env.aws-single

# Load the encrypted secret store (JWT keys, IoT device certs, etc.)
caytu-client -t aws-single secrets seed --in vault.json

# Ship compose stack + env files to the host and start
caytu-client -t aws-single env push
caytu-client -t aws-single up
caytu-client -t aws-single logs backend

# Wire TLS. Skip this if you set the DNS block above — provision already did it.
# Otherwise point your domain at the EIP first, then:
caytu-client -t aws-single ssl bootstrap client.example.com ops@example.com
```

## DNS and TLS

`aws provision` prints the public IP, instance id, and domain when it finishes.
You can re-check the DNS side any time:

```bash
caytu-client -t aws-single aws dns       # domain vs. EIP vs. what actually resolves
caytu-client -t aws-single ssl status    # issuer + days until expiry
```

With `enable_route53 = true` and `letsencrypt_email` set, provision creates the
A record, waits for it to resolve to the EIP, then issues the certificate
automatically. Set `SKIP_AUTO_SSL=1` to skip just the TLS step.

`ssl bootstrap` is safe to re-run — it skips issuance when the existing
certificate has more than 30 days left (so you don't burn Let's Encrypt rate
limits), renews when under 30, and takes `--force` to reissue regardless.

Renewal is automatic: the `certbot` sidecar checks every 12h, and nginx reloads
itself every 6h so a renewed certificate is actually served. To force it:

```bash
caytu-client -t aws-single ssl renew     # renews and reloads nginx
```

## Everyday verbs

```bash
caytu-client -t aws-single deploy                  # pull new images + recreate
caytu-client -t aws-single deploy backend frontend # only these services
caytu-client -t aws-single logs backend
caytu-client -t aws-single ps
caytu-client -t aws-single ssh                     # shell on the host
caytu-client -t aws-single aws allow-me            # refresh THIS laptop's IP in the SG
caytu-client -t aws-single aws instance info       # state / type / IP / launch time
caytu-client -t aws-single aws instance stop       # pause billing for the compute (EIP + EBS keep costing)
caytu-client -t aws-single aws instance start
caytu-client -t aws-single aws instance resize m6g.xlarge
```

## Monitoring

```bash
caytu-client -t aws-single monitor up
caytu-client -t aws-single monitor tunnel grafana  # http://localhost:3005
caytu-client -t aws-single monitor tunnel dozzle
```

## Backups

Terraform created an S3 bucket for offsite. `.env.aws-single` was patched with the right `RESTIC_REPOSITORY`. Fill in a strong `RESTIC_PASSWORD` and go:

```bash
$EDITOR compose/.env.aws-single         # set RESTIC_PASSWORD
caytu-client -t aws-single env push
caytu-client -t aws-single backup enable
```

The instance's IAM role already has `s3:GetObject`/`PutObject` on the bucket — no access keys needed.

See [backup-restore.md](backup-restore.md) for restore procedures.

## AWS IoT Core + KVS

The Terraform apply provisioned:

- `caytu-client-<env>-device` — IoT policy attached to device certificates
- `caytu-client-<env>-iot-kvs` — IAM role with KVS signaling permissions
- `caytu-client-<env>-kvs` — IoT role alias (devices reference this in the client-cert credential flow)

**Per-device provisioning** (per camera / per robot) is out of scope for this repo; do it via your device-onboarding workflow. When you register a device:

1. Create an IoT Thing.
2. Create + attach an X.509 cert.
3. Attach the `caytu-client-<env>-device` IoT policy to the cert.
4. Ship the cert + private key + `AmazonRootCA1.pem` to the device.
5. Configure the device to fetch KVS credentials from `credentials.<endpoint>/role-aliases/caytu-client-<env>-kvs/credentials`.

KVS signaling channels are also per-device / per-camera — the app creates them on demand.

## Where things live

| On your workstation | On the EC2 host |
|---|---|
| `terraform/aws/single-instance/` — Terraform config + state | `/opt/caytu-client/compose/` — rsynced compose tree + env files |
| `terraform/aws/single-instance/ssh_key.pem` — private key | `/opt/caytu-client/compose/.env` — symlink to `.env.aws-single` |
| `.caytu-client-state.json` — ssh_host, instance_id, sg_id | `/opt/caytu-client/backups/` — local snapshots before S3 upload |
| `compose/.env.aws-single` — deployment config | Docker named volumes for mongo, minio, redis |

## Tearing down

```bash
caytu-client -t aws-single aws destroy
```

This runs `terraform destroy`. The backup bucket needs to be emptied first (`aws s3 rm --recursive s3://<bucket>`) or Terraform will refuse. Registry (ECR) images are also destroyed — export any you want to preserve first.

## Cost

- r6g.large + 100 GB gp3 + EIP + typical traffic: **~$70-90/mo baseline**
- IoT Core: pennies per million messages
- KVS signaling: per-minute during active sessions
- S3 backups: ~$0.023/GB (Standard) → $0.004/GB (Glacier after 90d)

Bump `instance_type` in tfvars when you outgrow it; `aws instance resize` handles the swap without recreating the machine.
