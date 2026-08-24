# CI access

The roles GitHub Actions assumes, so this repository holds no AWS keys. A key
works until somebody remembers to delete it; OIDC mints a token per run that
expires with the run.

Three roles, each able to do one job and nothing else:

| Role | What it does |
|---|---|
| `caytu-client-infra-provisioning` | Builds deployments. Runs Terraform, and steps into a customer account when there is one. |
| `caytu-client-infra-agent-publish` | Writes the agent tarball to one S3 prefix. Nothing else. |
| `caytu-client-infra-ci-access` | Applies this module when it changes. |

## Almost nothing here is manual

Two things used to need a person and no longer do.

**Onboarding a customer.** Letting their account pull our images and fetch the
agent was two Terraform applies run by hand with a tfvars file. That does not
survive a second customer. Provisioning does it on its way through, in
[`scripts/grant-customer-artifacts.sh`](../../../scripts/grant-customer-artifacts.sh).

**Changing what provisioning may do.** This module used to be applied by hand
after merging, and forgetting was quiet: the permission was merged, everyone
assumed it was live, and the next provision died on an access denied for an
action that had been in the repository for days. That happened twice in one
afternoon. `Apply-ci-access.yml` plans on a pull request and applies on main.

## Two things are manual, once, and only once

**The first apply of this module.** The workflow that applies it assumes
`caytu-client-infra-ci-access`, and that role is created by this Terraform. It
cannot create the role it needs in order to run. So the first apply is by hand,
and no apply after it is.

**The two repository variables.** They tell the workflow which role to assume
and which DNS zone hosted deployments live in. Terraform does not manage this
repository's settings, so only a person can set them the first time.

Neither is a design we settled for. Both are the bootstrap any self-applying
pipeline has, and both are done.

```bash
# Once, from main.
AWS_PROFILE=<profile> terraform init \
  -backend-config="bucket=<state bucket>" \
  -backend-config="key=ci-access/terraform.tfstate" \
  -backend-config="region=us-east-1" -backend-config="encrypt=true"

AWS_PROFILE=<profile> terraform apply \
  -var region=us-east-1 -var aws_profile=<profile> \
  -var state_bucket=<state bucket> \
  -var 'hosted_dns_zone_ids=["<zone id>"]'

# Then, from the outputs.
gh variable set AWS_CI_ACCESS_ROLE_ARN --body "<ci_access_role_arn>"
gh variable set HOSTED_DNS_ZONE_IDS --body '["<zone id>"]'
```

Until those variables exist the workflow says so, rather than failing on "could
not load credentials", which reads like a broken workflow rather than one nobody
has bootstrapped.

## Why three roles and not one

A role that can do everything is a role whose compromise costs everything. The
publish role touches one S3 prefix, so a bad run there cannot reach EC2 or IAM.

The applying role is separate from the provisioning role for a sharper reason.
Provisioning may manage `caytu-*` roles and is itself named `caytu-*`, so it
could have rewritten the policy that constrains it. In a customer account the
permissions boundary closes that. In ours there is no boundary, so it now
carries an explicit deny on its own ARN, which also means it can no longer apply
this module. Hence the third role, which carries the same deny on itself.

## Adding a customer

Nothing to do here. `customer_role_arns` is a pattern rather than a list,
because the list was never the security boundary: their trust policy names our
exact role and demands an external id only we hold, so a role we are not meant
to touch cannot be assumed whatever our side says.

## Retiring the old keys

Once provision, destroy, power and publish have each run green on OIDC, delete
`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` from the repository secrets and
deactivate the key in IAM. Nothing reads them any more, and leaving them keeps
the exposure this was meant to remove.
