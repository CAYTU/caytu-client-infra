# S3 bucket for backup CronJobs (see docs/aws-cluster.md).

resource "random_id" "backup_bucket" {
  count       = var.create_backup_bucket && var.backup_bucket_name == "" ? 1 : 0
  byte_length = 4
}

locals {
  backup_bucket_name = var.create_backup_bucket ? (
    var.backup_bucket_name != "" ? var.backup_bucket_name : "${var.name_prefix}-${var.environment}-cluster-backups-${random_id.backup_bucket[0].hex}"
  ) : ""
}

resource "aws_s3_bucket" "backups" {
  count  = var.create_backup_bucket ? 1 : 0
  bucket = local.backup_bucket_name
}

resource "aws_s3_bucket_versioning" "backups" {
  count  = var.create_backup_bucket ? 1 : 0
  bucket = aws_s3_bucket.backups[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  count  = var.create_backup_bucket ? 1 : 0
  bucket = aws_s3_bucket.backups[0].id
  rule { apply_server_side_encryption_by_default { sse_algorithm = "AES256" } }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  count                   = var.create_backup_bucket ? 1 : 0
  bucket                  = aws_s3_bucket.backups[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# IRSA for a backup CronJob. Bind to a service account named "backup" in the
# caytu-client namespace when you deploy the CronJob.
data "aws_iam_policy_document" "backup_assume" {
  count = var.create_backup_bucket ? 1 : 0
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:caytu-client:backup"]
    }
  }
}

resource "aws_iam_role" "backup" {
  count              = var.create_backup_bucket ? 1 : 0
  name               = "${var.name_prefix}-${var.environment}-backup"
  assume_role_policy = data.aws_iam_policy_document.backup_assume[0].json
}

data "aws_iam_policy_document" "backup" {
  count = var.create_backup_bucket ? 1 : 0
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.backups[0].arn]
  }
  statement {
    actions = [
      "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
      "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"
    ]
    resources = ["${aws_s3_bucket.backups[0].arn}/*"]
  }
}

resource "aws_iam_policy" "backup" {
  count  = var.create_backup_bucket ? 1 : 0
  name   = "${var.name_prefix}-${var.environment}-backup"
  policy = data.aws_iam_policy_document.backup[0].json
}

resource "aws_iam_role_policy_attachment" "backup" {
  count      = var.create_backup_bucket ? 1 : 0
  role       = aws_iam_role.backup[0].name
  policy_arn = aws_iam_policy.backup[0].arn
}
