# Letting a customer account pull our images without giving it a credential.
#
# The instance role in their account already carries ECR read permission. What
# was missing is the other half: our repositories saying that account may pull.
# Nothing is copied and no image leaves our registry.

data "aws_iam_policy_document" "pull" {
  for_each = length(var.customer_accounts) > 0 ? toset(var.image_repositories) : toset([])

  dynamic "statement" {
    for_each = { for c in var.customer_accounts : c.account_id => c }
    content {
      sid    = "Pull${replace(statement.value.label, "/[^0-9A-Za-z]/", "")}"
      effect = "Allow"
      actions = [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:DescribeImages",
        "ecr:ListImages",
      ]

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
}

resource "aws_ecr_repository_policy" "pull" {
  for_each = data.aws_iam_policy_document.pull

  repository = each.key
  policy     = each.value.json
}
