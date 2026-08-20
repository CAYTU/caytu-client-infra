# Distribution access

Runs in Caytu's account. It decides who may pull our images and who may fetch
the host agent. Nothing here provisions a deployment.

Two things it fixes.

**The agent tarball was public.** The bucket serves an apt repository and an
installer, which are meant to be public, and one statement granted
`s3:GetObject` on the whole bucket to everyone. That made `agent/latest.tar.gz`
downloadable with no credentials, and that tarball is `scripts/` and `compose/`
from this private repository. This splits the statement by prefix: the apt
repository and installer stay public, the agent prefix is readable only by our
own account and by accounts we name.

**Customer accounts could not pull images.** A machine in another account
already carries ECR read permission through its instance role, but our
repositories never said that account may pull. This adds a repository policy per
repository. Nothing is copied and no image leaves our registry.

## Adding a customer

```hcl
customer_accounts = [
  { account_id = "111122223333", label = "joj" },
]
```

Then:

```bash
terraform init
terraform plan -var-file=terraform.tfvars
terraform apply
```

Only a role named `caytu-*` in that account is granted, which is what
`terraform/aws/customer-onboarding` creates. Their other principals get nothing.

## First apply

The bucket policy already exists and is not in state, so the first plan shows it
as created. Applying replaces the live policy in one call. Read the rendered
statements before applying, and check afterwards that the apt repository still
serves:

```bash
curl -sI https://caytu-cli.s3.amazonaws.com/install.sh | head -1
curl -sI https://caytu-cli.s3.amazonaws.com/agent/latest.tar.gz | head -1
```

The first should be 200 and the second 403.
