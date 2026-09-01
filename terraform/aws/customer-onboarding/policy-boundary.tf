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


  # A cluster's roles, when this account holds one.
  #
  # The boundary intersects with whatever policy a role carries, so without
  # this the AWS managed policies EKS attaches to its own node role would be
  # capped to nothing and the nodes would never join.
  dynamic "statement" {
    for_each = var.include_cluster ? [1] : []
    content {
      sid    = "ClusterNodesAndAddons"
      effect = "Allow"
      actions = [
        # The VPC CNI hands each pod an address off the node's interface.
        "ec2:CreateNetworkInterface",
        "ec2:DeleteNetworkInterface",
        "ec2:AttachNetworkInterface",
        "ec2:DetachNetworkInterface",
        "ec2:ModifyNetworkInterfaceAttribute",
        "ec2:AssignPrivateIpAddresses",
        "ec2:UnassignPrivateIpAddresses",
        "ec2:CreateTags",
        # Volumes for anything that keeps state.
        "ec2:CreateVolume",
        "ec2:DeleteVolume",
        "ec2:AttachVolume",
        "ec2:DetachVolume",
        "ec2:ModifyVolume",
        "ec2:CreateSnapshot",
        "ec2:DeleteSnapshot",
        # The load balancer controller turns an ingress into a real balancer,
        # and gives it its own security group so the nodes can be reached by it
        # and nothing else. It creates that group itself, which the boundary has
        # to allow or the ingress never gets an address and the deployment is
        # unreachable with every pod healthy.
        "ec2:CreateSecurityGroup",
        "ec2:DeleteSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:AuthorizeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupEgress",
        "elasticloadbalancing:*",
        "acm:DescribeCertificate",
        "acm:ListCertificates",
        # The autoscaler adds and removes nodes.
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup",
        "eks:DescribeCluster",
      ]
      resources = ["*"]
    }
  }

  # Reads the add-ons make constantly. Separate because they are describes, and
  # keeping them apart makes the block above readable as "what may change".
  dynamic "statement" {
    for_each = var.include_cluster ? [1] : []
    content {
      sid    = "ClusterReads"
      effect = "Allow"
      actions = [
        "ec2:Describe*",
        "autoscaling:Describe*",
        "elasticloadbalancing:Describe*",
      ]
      resources = ["*"]
    }
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
