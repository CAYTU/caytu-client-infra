data "aws_caller_identity" "current" {}

# Locks each deployment's secret-store shard before it is written to the
# database. Values are a few hundred bytes, so KMS encrypts them directly and
# there is no data key to manage.
resource "aws_kms_key" "deployment_secrets" {
  description             = "Per-deployment secret material held by the platform"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "deployment_secrets" {
  name          = "alias/caytu-deployment-secrets"
  target_key_id = aws_kms_key.deployment_secrets.key_id
}

# The platform host already has an instance role. This is one more permission
# on it, not a new credential.
data "aws_iam_policy_document" "use_key" {
  statement {
    effect    = "Allow"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
    resources = [aws_kms_key.deployment_secrets.arn]
  }
}

resource "aws_iam_role_policy" "use_key" {
  name   = "deployment-secrets-kms"
  role   = var.platform_role_name
  policy = data.aws_iam_policy_document.use_key.json
}
