data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# Generated when the operator does not supply one, so a role can never end up
# with an empty external id and a trust policy that only checks the account.
resource "random_password" "external_id" {
  count   = var.external_id == "" ? 1 : 0
  length  = 40
  special = false
}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  partition   = data.aws_partition.current.partition
  external_id = var.external_id != "" ? var.external_id : random_password.external_id[0].result

  prefix = var.resource_prefix

  role_arn_pattern             = "arn:${local.partition}:iam::${local.account_id}:role/${local.prefix}*"
  instance_profile_arn_pattern = "arn:${local.partition}:iam::${local.account_id}:instance-profile/${local.prefix}*"
  policy_arn_pattern           = "arn:${local.partition}:iam::${local.account_id}:policy/${local.prefix}*"
  bucket_arn_pattern           = "arn:${local.partition}:s3:::${local.prefix}*"
}

# Two conditions, not one. The account alone lets any principal in Caytu's
# account assume this; the external id is what stops a confused deputy.
data "aws_iam_policy_document" "assume" {
  statement {
    sid     = "CaytuProvisioning"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "AWS"
      identifiers = var.caytu_principal_arns
    }

    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [local.external_id]
    }
  }
}

resource "aws_iam_role" "provisioner" {
  name                 = var.role_name
  description          = "Assumed by Caytu to provision and maintain the caytu-client deployment in this account."
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  max_session_duration = var.session_duration_seconds
}

resource "aws_iam_role_policy_attachment" "provisioner" {
  role       = aws_iam_role.provisioner.name
  policy_arn = aws_iam_policy.provisioner.arn
}
