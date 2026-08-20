# Who may read the host agent.
#
# The bucket serves two different things. The apt repository and the installer
# are meant to be public. The agent tarball is the contents of this private
# repository, and was public only because one statement granted s3:GetObject on
# the whole bucket to everyone. Splitting the statement by prefix is the fix.

data "aws_caller_identity" "current" {}

locals {
  bucket_arn   = "arn:aws:s3:::${var.agent_bucket}"
  agent_arn    = "${local.bucket_arn}/${var.agent_prefix}/*"
  own_account  = data.aws_caller_identity.current.account_id
  public_arns  = [for o in var.public_objects : "${local.bucket_arn}/${o}"]
  reader_accts = [for c in var.customer_accounts : c.account_id]
}

data "aws_iam_policy_document" "agent_bucket" {
  statement {
    sid       = "PublicReadAptAndInstaller"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = local.public_arns

    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }

  # Our own machines read it with their instance role, which lives here.
  statement {
    sid       = "CaytuHostedMachines"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = [local.agent_arn]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.own_account}:root"]
    }
  }

  # A customer account may read the agent, but only through a role we created
  # there. Their other principals get nothing.
  dynamic "statement" {
    for_each = { for c in var.customer_accounts : c.account_id => c }
    content {
      sid       = "Customer${replace(statement.value.label, "/[^0-9A-Za-z]/", "")}"
      effect    = "Allow"
      actions   = ["s3:GetObject"]
      resources = [local.agent_arn]

      principals {
        type        = "AWS"
        identifiers = ["arn:aws:iam::${statement.value.account_id}:root"]
      }

      condition {
        test     = "ArnLike"
        variable = "aws:PrincipalArn"
        values   = ["arn:aws:iam::${statement.value.account_id}:role/${statement.value.resource_prefix}*"]
      }
    }
  }

  # Belt and braces. If a future statement widens the bucket again, the agent
  # prefix still refuses anonymous callers.
  statement {
    sid       = "AgentIsNeverAnonymous"
    effect    = "Deny"
    actions   = ["s3:GetObject"]
    resources = [local.agent_arn]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    # No principal arn means nobody signed the request. Adding a second
    # condition here would AND with this one and could silently never match.
    condition {
      test     = "Null"
      variable = "aws:PrincipalArn"
      values   = ["true"]
    }
  }
}

resource "aws_s3_bucket_policy" "agent" {
  bucket = var.agent_bucket
  policy = data.aws_iam_policy_document.agent_bucket.json
}
