# ECR repositories for the app service images. Toggle via variables.tf.

resource "aws_ecr_repository" "svc" {
  for_each = toset(var.ecr_repositories)

  name                 = "${var.name_prefix}-${each.value}"
  image_tag_mutability = var.ecr_image_tag_mutability

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# Simple lifecycle: keep last 30 images tagged with a semver-ish tag, and drop
# untagged after 7 days. Cheap way to bound registry sprawl.
resource "aws_ecr_lifecycle_policy" "svc" {
  for_each = aws_ecr_repository.svc

  repository = each.value.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "keep last 30 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "latest", "staging", "prod", "arm64", "amd64"]
          countType     = "imageCountMoreThan"
          countNumber   = 30
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "drop untagged after 7d"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      }
    ]
  })
}
