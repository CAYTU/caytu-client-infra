# CloudFormation

`caytu-provisioner-access.yaml` is what a customer runs in their own AWS
account to give us access. It is the same role and the same permissions
boundary as `terraform/aws/customer-onboarding`, in the form a customer can
actually use: no repository to clone, no Terraform to install, and no ARN to
edit by hand, because CloudFormation fills in the account and the region
itself.

Generated from `terraform/aws/modules/deployment-permissions`, so the two
cannot describe different permissions. Regenerate it rather than editing it,
and check the statement counts still match after any change to that module.

The console serves a copy of this file from the deployment wizard, so a change
here needs the copy under `web-v2/src/features/billings/assets/` updated too.
