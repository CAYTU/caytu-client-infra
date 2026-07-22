# IAM roles for cluster addons + IRSA for app pods.
#
# EBS CSI: IRSA role assumed by the driver's service account so it can
# create/attach/detach EBS volumes for PVCs.
#
# ALB Controller: IRSA role for aws-load-balancer-controller. Helm install
# is a post-apply step (see outputs.helm_commands).
#
# Application IRSA: two roles the operator can wire onto the backend and
# gstreamer-recorder service accounts for scoped access to KVS + IoT + S3
# backups without stuffing credentials into secrets.env.

# --- EBS CSI ----------------------------------------------------------------
data "aws_iam_policy_document" "ebs_csi_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.name_prefix}-${var.environment}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# --- AWS Load Balancer Controller -------------------------------------------
# Policy JSON is upstream-maintained; we vendor a slimmed-down copy inline.
data "aws_iam_policy_document" "alb_controller_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  name               = "${var.name_prefix}-${var.environment}-alb-controller"
  assume_role_policy = data.aws_iam_policy_document.alb_controller_assume.json
}

# For staging this coarse policy is fine; harden for prod using the upstream
# minified policy: https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
data "aws_iam_policy_document" "alb_controller" {
  statement {
    actions = [
      "elasticloadbalancing:*",
      "ec2:Describe*",
      "ec2:CreateSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:DeleteSecurityGroup",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "acm:ListCertificates",
      "acm:DescribeCertificate",
      "iam:CreateServiceLinkedRole",
      "iam:GetServerCertificate",
      "iam:ListServerCertificates",
      "cognito-idp:DescribeUserPoolClient",
      "waf-regional:GetWebACL",
      "wafv2:GetWebACL",
      "shield:GetSubscriptionState",
      "shield:DescribeProtection",
      "shield:CreateProtection",
      "shield:DeleteProtection",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "alb_controller" {
  name   = "${var.name_prefix}-${var.environment}-alb-controller"
  policy = data.aws_iam_policy_document.alb_controller.json
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

# --- Application IRSA: backend ---------------------------------------------
# Give the backend KVS signaling + IoT publish/subscribe + S3 backup access.
data "aws_iam_policy_document" "app_backend_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:caytu-client:backend"]
    }
  }
}

resource "aws_iam_role" "app_backend" {
  name               = "${var.name_prefix}-${var.environment}-backend"
  assume_role_policy = data.aws_iam_policy_document.app_backend_assume.json
}

data "aws_iam_policy_document" "app_backend" {
  statement {
    actions = [
      "kinesisvideo:DescribeSignalingChannel",
      "kinesisvideo:GetSignalingChannelEndpoint",
      "kinesisvideo:GetIceServerConfig",
      "kinesisvideo:ConnectAsMaster",
      "kinesisvideo:ConnectAsViewer",
      "kinesisvideo:CreateSignalingChannel",
      "kinesisvideo:ListSignalingChannels",
      "kinesisvideo:DeleteSignalingChannel",
      "iot:Connect", "iot:Publish", "iot:Subscribe", "iot:Receive",
      "iot:DescribeEndpoint",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "app_backend" {
  name   = "${var.name_prefix}-${var.environment}-backend"
  policy = data.aws_iam_policy_document.app_backend.json
}

resource "aws_iam_role_policy_attachment" "app_backend" {
  role       = aws_iam_role.app_backend.name
  policy_arn = aws_iam_policy.app_backend.arn
}
