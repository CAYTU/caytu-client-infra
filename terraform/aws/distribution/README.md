# Distribution access

Runs in Caytu's account. It decides what in our artifact bucket is public and
what is not. It no longer decides who may pull our images: provisioning does
that now.

## What it fixes

The bucket serves an apt repository and an installer, which are meant to be
public, and one statement granted `s3:GetObject` on the whole bucket to
everyone. That made `agent/latest.tar.gz` downloadable with no credentials, and
that tarball is `scripts/` and `compose/` from this private repository. This
splits the statement by prefix and adds an explicit deny for anonymous callers
on the agent prefix.

## Per-customer grants are not here

Onboarding a customer used to mean editing a variable and running an apply on
somebody's laptop, which does not survive a second customer. Provisioning does
it instead: `Provision.yml` runs
[`scripts/grant-customer-artifacts.sh`](../../../scripts/grant-customer-artifacts.sh)
with our own credentials before it steps into the customer account.

So this module reads the live policy and **keeps every `Customer<account>`
statement it finds**. Rebuilding the policy from only what this module knows
would revoke every customer the next time anyone applied it.

## Migrating off the old version

An earlier version managed the ECR repository policies here. Provisioning owns
them now, so release them rather than letting Terraform delete them. Deleting
them revokes every customer's pull access, and the failure appears later as a
machine that builds fine and then cannot start a single container.

```bash
for r in backend frontend mqtt-streamer gstreamer-recorder signaling-server; do
  terraform state rm "aws_ecr_repository_policy.pull[\"caytu-client-$r\"]"
done
terraform plan   # expect no changes
```

## Checking it

```bash
curl -sI https://caytu-cli.s3.amazonaws.com/install.sh | head -1          # 200
curl -sI https://caytu-cli.s3.amazonaws.com/agent/latest.tar.gz | head -1 # 403
```
