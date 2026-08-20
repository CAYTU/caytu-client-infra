# CI access

Runs in Caytu's account. Creates the two roles GitHub Actions assumes, so this
repository stops holding static AWS keys.

Today `Provision.yml` and `Publish-agent.yml` both read
`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` from GitHub secrets. Those are
long-lived credentials that can create and destroy in the production account.
OIDC replaces them with a token minted per run, valid for that run only.

The OIDC provider already exists in the account. It was created for the platform
repository, and these roles reuse it.

## Two roles, not one

`caytu-client-infra-provisioning` runs Terraform. It gets the deployment
permission set, the Terraform state bucket, the caytu.link zone, and permission
to assume named customer roles. Nothing else.

`caytu-client-infra-agent-publish` writes the agent tarball to one S3 prefix. It
cannot touch EC2, IAM, or anything else.

## Apply

```bash
cp example.tfvars terraform.tfvars
$EDITOR terraform.tfvars      # state_bucket, the caytu.link zone id
terraform init && terraform apply
```

Then set the outputs as repository variables:

```
AWS_PROVISIONING_ROLE_ARN   = <provisioning_role_arn>
AWS_AGENT_PUBLISH_ROLE_ARN  = <agent_publish_role_arn>
```

Once both workflows run green on OIDC, delete `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY` from the repository secrets and deactivate the key in
IAM. Leaving them in place keeps the exposure this was meant to remove.

## Adding a customer

Append their provisioner role to `customer_role_arns` and apply. The pipeline
cannot assume a role that is not on that list.
