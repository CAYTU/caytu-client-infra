# Customer AWS access

A customer running a deployment in their own AWS account has to let our
pipeline in. This is how that happens, and what each piece is for.

## What the customer does

One CloudFormation stack, from the console, in the region the deployment will
run in. Nothing else: no repository to clone, no Terraform to install, and no
ARN to edit by hand, because CloudFormation fills in the account and the region
itself.

They read [the guide the console links to](../../Caytu-Infra/web-v2/src/features/billings/pages/aws-access-guide-page.tsx),
which is served publicly at `/docs/aws-access` because their cloud team has no
Caytu login. It hands them
[`cloudformation/caytu-provisioner-access.yaml`](../cloudformation/caytu-provisioner-access.yaml)
to download, walks the five console steps, and shows the full template inline
so their security team can read it without going anywhere else.

They send back four values: account number, region, role ARN, and permissions
boundary ARN. The fifth value, the external id, goes the other way: the console
generates it and they paste it into the stack.

## Why the external id comes from us

It is what stops anyone else assuming that role, so leaving customers to invent
one means some of them will pick something weak or reuse one. Generating it is
cheap and it is our failure if it is bad.

It is not a credential on its own. The trust policy names exactly one principal,
our provisioning role, and only a run of our own pipeline can assume that. The
external id closes the confused-deputy case and nothing else.

## Where the permissions actually live

[`terraform/aws/modules/deployment-permissions`](../terraform/aws/modules/deployment-permissions)
is the single definition, used by our own pipeline role and by the customer
role. The CloudFormation template is generated from it. Two hand-maintained
copies would drift, and the drift would only show up as a failed apply on a
customer's machine.

[`terraform/aws/customer-onboarding`](../terraform/aws/customer-onboarding) is
the same thing as a Terraform module. It stays for a customer whose platform
team would rather run Terraform than click through a console, and as the thing
the template is checked against.

## After a customer is onboarded

Add their account to
[`terraform/aws/distribution`](../terraform/aws/distribution) and apply, so
their machine can pull our images and fetch the host agent. Nothing works until
that is done, and the failure looks like an image pull error on a machine that
otherwise came up fine.
