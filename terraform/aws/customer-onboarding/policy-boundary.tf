# The ceiling on every role Caytu creates here.
#
# The provisioner may create roles, which is the one permission on this list
# that could otherwise be used to escalate. Requiring this boundary on each
# CreateRole means a role it invents can never do more than the deployment
# itself needs, whatever policy gets attached to it.

data "aws_iam_policy_document" "boundary" {
  statement {
    sid    = "PullImages"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeRepositories",
      "ecr:DescribeImages",
      "ecr:ListImages",
    ]
    resources = ["*"]
  }

  # Session Manager, so nobody needs an SSH key on the box.
  statement {
    sid    = "SessionManager"
    effect = "Allow"
    actions = [
      "ssm:UpdateInstanceInformation",
      "ssm:ListInstanceAssociations",
      "ssm:DescribeInstanceProperties",
      "ssm:DescribeDocumentParameters",
      "ssm:GetDeployablePatchSnapshotForInstance",
      "ssm:GetDocument",
      "ssm:DescribeDocument",
      "ssm:GetManifest",
      "ssm:PutInventory",
      "ssm:PutComplianceItems",
      "ssm:PutConfigurePackageResult",
      "ssm:UpdateAssociationStatus",
      "ssm:UpdateInstanceAssociationStatus",
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
      "ec2messages:AcknowledgeMessage",
      "ec2messages:DeleteMessage",
      "ec2messages:FailMessage",
      "ec2messages:GetEndpoint",
      "ec2messages:GetMessages",
      "ec2messages:SendReply",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AgentAndBackups"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
      "s3:ListBucket",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "DeviceMessagingAndVideo"
    effect = "Allow"
    actions = [
      "iot:Connect",
      "iot:Publish",
      "iot:Subscribe",
      "iot:Receive",
      "iot:DescribeEndpoint",
      "iot:AssumeRoleWithCertificate",
      "iot:CreateThing",
      "iot:DescribeThing",
      "iot:ListThings",
      "kinesisvideo:DescribeSignalingChannel",
      "kinesisvideo:GetSignalingChannelEndpoint",
      "kinesisvideo:GetIceServerConfig",
      "kinesisvideo:ConnectAsMaster",
      "kinesisvideo:ConnectAsViewer",
      "kinesisvideo:CreateSignalingChannel",
      "kinesisvideo:ListSignalingChannels",
      "kinesisvideo:DeleteSignalingChannel",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ReadEncryptedVolumesAndObjects"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "OwnLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["*"]
  }

  # The point of the whole file. Without this a created role could be handed a
  # policy granting IAM, and the boundary would have bought nothing.
  statement {
    sid    = "NeverIdentityOrBilling"
    effect = "Deny"
    actions = [
      "iam:*",
      "sts:AssumeRole",
      "organizations:*",
      "account:*",
      "billing:*",
      "aws-portal:*",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "boundary" {
  name        = "${var.role_name}Boundary"
  description = "Ceiling for every role the Caytu provisioner creates in this account."
  policy      = data.aws_iam_policy_document.boundary.json
}
