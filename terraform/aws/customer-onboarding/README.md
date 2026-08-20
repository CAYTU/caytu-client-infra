# Giving Caytu access to your AWS account

Run this once, in the account where the deployment will live. It creates one
role Caytu can assume and one permissions boundary that caps what that role can
ever do. It creates nothing else, and it does not deploy the application.

You keep the account. Caytu never receives a key, a password, or a console
login.

## What you need

- Terraform >= 1.6
- Credentials for the target account with permission to create IAM roles and
  policies
- From Caytu: the ARN of the identity that will assume the role, and the region

## Run it

```bash
cp example.tfvars terraform.tfvars
$EDITOR terraform.tfvars      # set region and caytu_principal_arns

terraform init
terraform plan
terraform apply
```

Then send Caytu these four values. The external id is a secret, so send it over
a private channel rather than in the same email as the rest.

```bash
terraform output what_to_send_caytu
terraform output -raw external_id
```

## What the role may do

Everything is limited three ways at once.

**One region.** Every regional call is refused outside the region you set.

**One name prefix.** Caytu may only create, read or delete resources whose name
starts with `caytu-`. It cannot see or touch anything else you run.

**A boundary on every role it creates.** The role may create IAM roles, because
the EC2 instance needs one. `CreateRole` is refused unless the boundary created
here is attached, so a role Caytu creates can only ever pull images, use Session
Manager, read and write its own S3 prefixes, and talk to IoT Core and Kinesis
Video. The boundary denies all of `iam:*`, so that path cannot be used to widen
access.

## What gets created in your account when Caytu deploys

One EC2 instance and an Elastic IP, one security group, an instance role and
instance profile, the ECR repositories for the application images, an S3 bucket
for backups, and an IoT policy with a role alias for device authentication.

## Turning it off

Revoking access is deleting the role:

```bash
terraform destroy
```

Anything Caytu already created stays. Delete the deployment first if you want it
gone, or remove those resources yourself afterwards.
