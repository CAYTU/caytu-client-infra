data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  # Already present in the account, created for the other repository.
  oidc_provider_arn = "arn:${local.partition}:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"

  # Both forms. Which one a repository issues is a GitHub-side setting we do
  # not control, and it can change under us, so trust either rather than
  # discovering the difference as a failed deploy.
  repo_forms = compact([
    var.github_repository,
    var.github_repository_immutable,
  ])

  subs = flatten([
    for form in local.repo_forms : [
      for r in var.allowed_refs : "repo:${form}:${r}"
    ]
  ])
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # The ref, not just the repository. A token minted by any branch would
    # otherwise be enough to provision production.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.subs
    }
  }
}

# -----------------------------------------------------------------------------
# Provisioning
# -----------------------------------------------------------------------------
resource "aws_iam_role" "provisioning" {
  name               = "caytu-client-infra-provisioning"
  description        = "Assumed by Provision.yml. Replaces the static access key that used to live in GitHub secrets."
  assume_role_policy = data.aws_iam_policy_document.github_assume.json
}

# Same list the customer role gets, so a Caytu-hosted apply and a customer apply
# cannot need different permissions.
module "deployment" {
  source = "../modules/deployment-permissions"

  account_id      = local.account_id
  partition       = local.partition
  regions         = var.deployment_regions
  resource_prefix = var.resource_prefix
  boundary_arn    = ""
  allow_route53   = true
  # Its own arn, so a provisioning run cannot widen the policy it runs under.
  protected_role_arns = [
    "arn:${local.partition}:iam::${local.account_id}:role/caytu-client-infra-provisioning",
  ]
  route53_zone_ids = var.hosted_dns_zone_ids
}

resource "aws_iam_role_policy" "deployment" {
  name   = "deployment"
  role   = aws_iam_role.provisioning.id
  policy = module.deployment.policy_json
}

data "aws_iam_policy_document" "pipeline" {
  statement {
    sid       = "TerraformState"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = ["arn:${local.partition}:s3:::${var.state_bucket}"]
  }

  statement {
    sid       = "OneStatePerDeployment"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:${local.partition}:s3:::${var.state_bucket}/instances/*"]
  }

  dynamic "statement" {
    for_each = var.state_lock_table != "" ? [1] : []
    content {
      sid       = "StateLock"
      effect    = "Allow"
      actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
      resources = ["arn:${local.partition}:dynamodb:${var.region}:${local.account_id}:table/${var.state_lock_table}"]
    }
  }

  # The one thing this role has that the customer role does not: the ability to
  # step into a customer account. Listed explicitly, never a wildcard.
  dynamic "statement" {
    for_each = length(var.customer_role_arns) > 0 ? [1] : []
    content {
      sid    = "EnterCustomerAccounts"
      effect = "Allow"
      # TagSession because configure-aws-credentials tags the session it opens,
      # so stopping or starting a customer's machine failed on a permission the
      # terraform provider never needed. Their trust policy already expects it.
      actions   = ["sts:AssumeRole", "sts:TagSession"]
      resources = var.customer_role_arns
    }
  }
}

resource "aws_iam_role_policy" "pipeline" {
  name   = "pipeline"
  role   = aws_iam_role.provisioning.id
  policy = data.aws_iam_policy_document.pipeline.json
}

# -----------------------------------------------------------------------------
# Publishing the agent
# -----------------------------------------------------------------------------
resource "aws_iam_role" "agent_publish" {
  name               = "caytu-client-infra-agent-publish"
  description        = "Assumed by Publish-agent.yml. Writes the agent tarball and nothing else."
  assume_role_policy = data.aws_iam_policy_document.github_assume.json
}

data "aws_iam_policy_document" "agent_publish" {
  statement {
    sid       = "PublishTheAgent"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
    resources = ["arn:${local.partition}:s3:::${var.agent_bucket}/${var.agent_prefix}/*"]
  }

  statement {
    sid       = "SeeTheBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:${local.partition}:s3:::${var.agent_bucket}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.agent_prefix}/*"]
    }
  }
}

resource "aws_iam_role_policy" "agent_publish" {
  name   = "publish"
  role   = aws_iam_role.agent_publish.id
  policy = data.aws_iam_policy_document.agent_publish.json
}

# -----------------------------------------------------------------------------
# Applying this module
# -----------------------------------------------------------------------------
# Every change to what provisioning may do used to mean somebody running
# terraform on a laptop, and forgetting meant the next provision failed on a
# permission that was already merged. This role lets the workflow do it.
#
# Deliberately not the provisioning role: that one is denied from rewriting
# itself, which is the point of the deny above.
# Its own trust document rather than the shared one, because it is the only
# role a pull request may assume.
data "aws_iam_policy_document" "ci_access_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = flatten([
        for form in local.repo_forms : [
          for r in var.ci_access_allowed_refs : "repo:${form}:${r}"
        ]
      ])
    }
  }
}

resource "aws_iam_role" "ci_access" {
  name               = "caytu-client-infra-ci-access"
  description        = "Assumed by Apply-ci-access.yml to manage the two CI roles."
  assume_role_policy = data.aws_iam_policy_document.ci_access_assume.json
}

data "aws_iam_policy_document" "ci_access" {
  statement {
    sid    = "ManageTheCiRoles"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListRoleTags",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
    ]
    resources = [
      aws_iam_role.provisioning.arn,
      aws_iam_role.agent_publish.arn,
      aws_iam_role.ci_access.arn,
    ]
  }

  # Same reasoning as the deny in the module: a role that can rewrite its own
  # trust policy is a role with no limits at all.
  # Writes only. Denying iam:* would deny reading it too, and terraform has to
  # refresh the very role it manages.
  statement {
    sid    = "NeverRewriteOurselves"
    effect = "Deny"
    actions = [
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:UpdateAssumeRolePolicy",
      "iam:DeleteRole",
    ]
    resources = [aws_iam_role.ci_access.arn]
  }

  statement {
    sid       = "ReadTheState"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = ["arn:${local.partition}:s3:::${var.state_bucket}"]
  }

  statement {
    sid       = "WriteOurOwnState"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:${local.partition}:s3:::${var.state_bucket}/ci-access/*"]
  }

  statement {
    sid       = "ReadWhatWeAttach"
    effect    = "Allow"
    actions   = ["iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions"]
    resources = ["arn:${local.partition}:iam::aws:policy/*"]
  }

  statement {
    sid       = "WhoAmI"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ci_access" {
  name   = "apply"
  role   = aws_iam_role.ci_access.id
  policy = data.aws_iam_policy_document.ci_access.json
}
