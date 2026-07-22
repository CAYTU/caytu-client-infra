# S3 bucket for restic offsite backups (see docs/backup-restore.md).
# Skip by setting create_backup_bucket = false and pointing RESTIC_REPOSITORY
# at an existing bucket / B2 / SFTP target instead.

resource "random_id" "backup_bucket" {
  count       = var.create_backup_bucket && var.backup_bucket_name == "" ? 1 : 0
  byte_length = 4
}

locals {
  backup_bucket_name = var.create_backup_bucket ? (
    var.backup_bucket_name != "" ? var.backup_bucket_name : "${var.name_prefix}-${var.environment}-backups-${random_id.backup_bucket[0].hex}"
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
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  count  = var.create_backup_bucket ? 1 : 0
  bucket = aws_s3_bucket.backups[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  count  = var.create_backup_bucket && var.backup_bucket_lifecycle_days > 0 ? 1 : 0
  bucket = aws_s3_bucket.backups[0].id

  rule {
    id     = "glacier-transition"
    status = "Enabled"
    filter {}

    transition {
      days          = var.backup_bucket_lifecycle_days
      storage_class = "GLACIER"
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }
  }
}

# Grant the instance write access to the backup bucket
data "aws_iam_policy_document" "instance_backup_s3" {
  count = var.create_backup_bucket ? 1 : 0

  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.backups[0].arn]
  }
  statement {
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:GetObjectVersion",
      "s3:DeleteObjectVersion",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${aws_s3_bucket.backups[0].arn}/*"]
  }
}

resource "aws_iam_policy" "instance_backup_s3" {
  count  = var.create_backup_bucket ? 1 : 0
  name   = "${var.name_prefix}-${var.environment}-backup-s3"
  policy = data.aws_iam_policy_document.instance_backup_s3[0].json
}

resource "aws_iam_role_policy_attachment" "instance_backup_s3" {
  count      = var.create_backup_bucket ? 1 : 0
  role       = aws_iam_role.instance.name
  policy_arn = aws_iam_policy.instance_backup_s3[0].arn
}
