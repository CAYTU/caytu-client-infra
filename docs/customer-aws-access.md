# Giving Caytu access to your AWS account

You are about to run a Caytu deployment in your own AWS account. Caytu builds
and maintains the machine; you own the account and the bill.

This is the one thing we need from you, and it takes about ten minutes. At the
end you paste four values into the Caytu console and you are done.

We never receive a key, a password, or a console login.

## Why a role and not a key

An access key is a password that works until somebody remembers to delete it. A
role is different: our pipeline asks AWS for a session each time it runs, the
session lasts one hour, and you can revoke it in one click by deleting the role.
Nothing of yours ever sits in our systems.

## What you create

One role, and one permissions boundary.

The **role** is what our pipeline assumes. Its trust policy names exactly one
identity on our side and demands a shared value called an external id, so no
other AWS customer can use it, and nothing else in our account can either.

The **permissions boundary** is the ceiling. Our pipeline has to create one IAM
role, because the EC2 machine needs an identity to pull images and to be
reachable through Session Manager. Creating roles is the only permission on the
list that could otherwise be used to widen access, so the policy refuses to
create a role unless this boundary is attached to it. The boundary allows the
machine to pull images, use Session Manager, read and write its own storage, and
talk to IoT Core and Kinesis Video. It denies all of `iam:*`, which closes that
door for good.

## Three limits, all at once

Everything we can do in your account is bounded three ways:

**One region.** Every call outside the region you choose is refused, including
by us.

**One name prefix.** We can only create, read or delete resources whose name
starts with `caytu-`. Anything else you run is invisible to us. We cannot list
your buckets, read your databases, or see your other instances.

**The boundary above.** Any role we create is capped by it, and we are not
allowed to remove or replace it.

## Run it

You need Terraform 1.6 or newer, and credentials for the account with permission
to create IAM roles.

```bash
git clone <the repository Caytu shared with you>
cd terraform/aws/customer-onboarding

cp example.tfvars terraform.tfvars
```

Edit two values in `terraform.tfvars`:

```hcl
# Where the deployment will run.
region = "eu-west-3"

# The Caytu identity allowed to assume the role. Caytu gives you this.
caytu_principal_arns = ["arn:aws:iam::688544396352:role/caytu-client-infra-provisioning"]
```

Then:

```bash
terraform init
terraform plan      # read it: four resources, all IAM, nothing else
terraform apply
```

## What to send back

```bash
terraform output what_to_send_caytu
terraform output -raw external_id
```

Four values go into the Caytu console:

| Value | What it is |
|---|---|
| `account_id` | Your AWS account number |
| `region` | The region you chose above |
| `provisioner_role_arn` | The role we assume |
| `external_id` | The value your trust policy demands from us |
| `permissions_boundary_arn` | The ceiling on any role we create |

The external id is the one worth sending privately rather than in the same email
as the rest.

## What we build once you have

One EC2 machine and a fixed public address, a security group, an identity for
the machine, the container registries for the application, a bucket for backups,
and an IoT policy so your devices can connect. Every one of them is named
`caytu-...`, so you can find them all in one filter and see nothing of ours
mixed into the rest of your account.

## Checking on us

Everything we do is a normal AWS API call from a named role, so it all lands in
CloudTrail under your account. Filter on the role name to see every action we
have ever taken.

## Turning it off

```bash
terraform destroy
```

The role is gone and we can no longer reach the account. The deployment itself
keeps running: ask Caytu to tear it down first if you want it removed, or delete
the `caytu-` resources yourself afterwards.
