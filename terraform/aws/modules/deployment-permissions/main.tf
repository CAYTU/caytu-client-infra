locals {
  role_arn_pattern             = "arn:${var.partition}:iam::${var.account_id}:role/${var.resource_prefix}*"
  instance_profile_arn_pattern = "arn:${var.partition}:iam::${var.account_id}:instance-profile/${var.resource_prefix}*"
  policy_arn_pattern           = "arn:${var.partition}:iam::${var.account_id}:policy/${var.resource_prefix}*"
  bucket_arn_pattern           = "arn:${var.partition}:s3:::${var.resource_prefix}*"
}

# What Caytu may do in this account.
#
# Derived from terraform/aws/single-instance, so it is the set that stack
# actually uses and nothing beyond it. Two guardrails run through the whole
# file: every regional call is pinned to one region, and every resource Caytu
# creates must carry the agreed name prefix.

data "aws_iam_policy_document" "provisioner" {
  statement {
    sid       = "WhoAmI"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }

  # Terraform reads the account's network, AMIs and current state on every plan.
  statement {
    sid    = "InspectTheAccount"
    effect = "Allow"
    actions = [
      "ec2:Describe*",
      "ec2:GetEbsEncryptionByDefault",
      "ec2:GetEbsDefaultKmsKeyId",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = var.regions
    }
  }

  statement {
    sid    = "RunTheMachine"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:StartInstances",
      "ec2:StopInstances",
      "ec2:TerminateInstances",
      "ec2:ModifyInstanceAttribute",
      "ec2:ModifyInstanceMetadataOptions",
      "ec2:MonitorInstances",
      "ec2:UnmonitorInstances",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "ec2:CreateSecurityGroup",
      "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:ModifySecurityGroupRules",
      "ec2:UpdateSecurityGroupRuleDescriptionsIngress",
      "ec2:UpdateSecurityGroupRuleDescriptionsEgress",
      "ec2:CreateKeyPair",
      "ec2:ImportKeyPair",
      "ec2:DeleteKeyPair",
      "ec2:AllocateAddress",
      "ec2:ReleaseAddress",
      "ec2:AssociateAddress",
      "ec2:DisassociateAddress",
      "ec2:CreateVolume",
      "ec2:DeleteVolume",
      "ec2:AttachVolume",
      "ec2:DetachVolume",
      "ec2:ModifyVolume",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = var.regions
    }
  }

  # The root volume is encrypted, so RunInstances has to grant EC2 use of the
  # key. ViaService keeps this from becoming general access to the key.
  statement {
    sid    = "EncryptTheRootVolume"
    effect = "Allow"
    actions = [
      "kms:CreateGrant",
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKeyWithoutPlaintext",
      "kms:ReEncryptFrom",
      "kms:ReEncryptTo",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values = flatten([
        for r in var.regions : ["ec2.${r}.amazonaws.com", "s3.${r}.amazonaws.com"]
      ])
    }
  }

  # Name-prefixed, so this cannot touch a role the account already had.
  statement {
    sid    = "ManageOurOwnRoles"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:GetRole",
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListRoleTags",
      "iam:UpdateAssumeRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListInstanceProfilesForRole",
    ]
    resources = [local.role_arn_pattern]
  }

  # Every role it creates carries the boundary, or the call is refused. This is
  # what keeps CreateRole from being a way out of this policy.
  # In a customer account the boundary closes this. In our own there is no
  # boundary, and the pipeline role is itself named caytu-*, so ManageOurOwnRoles
  # would otherwise let a run rewrite the policy that constrains it.
  dynamic "statement" {
    for_each = length(var.protected_role_arns) > 0 ? [1] : []
    content {
      sid       = "NeverRewriteOurselves"
      effect    = "Deny"
      resources = var.protected_role_arns
      actions = [
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:UpdateAssumeRolePolicy",
        "iam:DeleteRole",
      ]
    }
  }

  dynamic "statement" {
    for_each = var.boundary_arn != "" ? [1] : []
    content {
      # CreateRole only. That is where the boundary is set, and a policy
      # attached later is still capped by it, so guarding the attach actions
      # buys nothing and risks denying a legitimate call when the condition key
      # is absent.
      sid       = "TheBoundaryIsNotOptional"
      effect    = "Deny"
      actions   = ["iam:CreateRole"]
      resources = [local.role_arn_pattern]

      condition {
        test     = "StringNotEquals"
        variable = "iam:PermissionsBoundary"
        values   = [var.boundary_arn]
      }
    }
  }

  statement {
    sid    = "ManageOurOwnInstanceProfiles"
    effect = "Allow"
    actions = [
      "iam:CreateInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
    ]
    resources = [local.instance_profile_arn_pattern]
  }

  statement {
    sid    = "ManageOurOwnPolicies"
    effect = "Allow"
    actions = [
      "iam:CreatePolicy",
      "iam:GetPolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      "iam:ListEntitiesForPolicy",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]
    resources = [local.policy_arn_pattern]
  }

  # Terraform reads the AWS-managed policies it attaches, and reads the
  # boundary to confirm it still exists.
  statement {
    sid       = "ReadManagedPolicies"
    effect    = "Allow"
    actions   = ["iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions"]
    resources = compact(["arn:${var.partition}:iam::aws:policy/*", var.boundary_arn])
  }

  # Handing a role to EC2 and to IoT, and to nothing else.
  statement {
    sid       = "AttachRolesToServices"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [local.role_arn_pattern]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com", "credentials.iot.amazonaws.com"]
    }
  }

  # iot:CreateRoleAlias does not set iam:PassedToService, so the statement above
  # cannot match it and provisioning failed on the last resource it creates,
  # after the machine was already running. Scoped by role name instead, which is
  # the control that was doing the work anyway.
  statement {
    sid     = "AttachTheDeviceCredentialRole"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [
      "arn:${var.partition}:iam::${var.account_id}:role/${var.resource_prefix}*-iot-kvs",
    ]
  }

  statement {
    sid    = "OurRegistry"
    effect = "Allow"
    actions = [
      "ecr:CreateRepository",
      "ecr:DeleteRepository",
      "ecr:DescribeRepositories",
      "ecr:PutLifecyclePolicy",
      "ecr:GetLifecyclePolicy",
      "ecr:DeleteLifecyclePolicy",
      "ecr:PutImageScanningConfiguration",
      "ecr:SetRepositoryPolicy",
      "ecr:GetRepositoryPolicy",
      "ecr:DeleteRepositoryPolicy",
      "ecr:TagResource",
      "ecr:UntagResource",
      "ecr:ListTagsForResource",
    ]
    resources = [
      for r in var.regions :
      "arn:${var.partition}:ecr:${r}:${var.account_id}:repository/${var.resource_prefix}*"
    ]
  }

  statement {
    sid       = "DescribeRegistry"
    effect    = "Allow"
    actions   = ["ecr:DescribeRegistry", "ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "BackupBucket"
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:GetBucketVersioning",
      "s3:PutBucketVersioning",
      "s3:GetBucketTagging",
      "s3:PutBucketTagging",
      "s3:GetBucketPolicy",
      "s3:PutBucketPolicy",
      "s3:DeleteBucketPolicy",
      "s3:GetBucketAcl",
      "s3:GetBucketCORS",
      "s3:GetBucketWebsite",
      "s3:GetBucketLogging",
      "s3:GetBucketRequestPayment",
      "s3:GetBucketObjectLockConfiguration",
      "s3:GetAccelerateConfiguration",
      "s3:GetReplicationConfiguration",
      "s3:GetEncryptionConfiguration",
      "s3:PutEncryptionConfiguration",
      "s3:GetLifecycleConfiguration",
      "s3:PutLifecycleConfiguration",
      "s3:GetBucketPublicAccessBlock",
      "s3:PutBucketPublicAccessBlock",
    ]
    resources = [local.bucket_arn_pattern, "${local.bucket_arn_pattern}/*"]
  }

  statement {
    sid    = "DeviceAuth"
    effect = "Allow"
    actions = [
      "iot:CreatePolicy",
      "iot:GetPolicy",
      "iot:DeletePolicy",
      "iot:ListPolicyVersions",
      "iot:DeletePolicyVersion",
      "iot:CreateRoleAlias",
      "iot:DescribeRoleAlias",
      "iot:UpdateRoleAlias",
      "iot:DeleteRoleAlias",
      "iot:TagResource",
      "iot:UntagResource",
      "iot:ListTagsForResource",
    ]
    resources = flatten([
      for r in var.regions : [
        "arn:${var.partition}:iot:${r}:${var.account_id}:policy/${var.resource_prefix}*",
        "arn:${var.partition}:iot:${r}:${var.account_id}:rolealias/${var.resource_prefix}*",
      ]
    ])
  }

  statement {
    sid       = "IotEndpoint"
    effect    = "Allow"
    actions   = ["iot:DescribeEndpoint"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = var.regions
    }
  }

  dynamic "statement" {
    for_each = var.allow_route53 ? [1] : []
    content {
      sid    = "DnsRecords"
      effect = "Allow"
      # ListTagsForResource because the aws_route53_zone data source reads the
      # zone's tags on every plan, not just its records.
      actions = [
        "route53:ChangeResourceRecordSets",
        "route53:ListResourceRecordSets",
        "route53:GetHostedZone",
        "route53:ListTagsForResource",
      ]
      resources = length(var.route53_zone_ids) > 0 ? [for z in var.route53_zone_ids : "arn:${var.partition}:route53:::hostedzone/${z}"] : ["arn:${var.partition}:route53:::hostedzone/*"]
    }
  }

  dynamic "statement" {
    for_each = var.allow_route53 ? [1] : []
    content {
      sid       = "DnsLookup"
      effect    = "Allow"
      actions   = ["route53:ListHostedZones", "route53:ListHostedZonesByName", "route53:GetChange"]
      resources = ["*"]
    }
  }
}


# A cluster, as its own policy.
#
# Separate from the document above because the two together are over 9,000
# characters and a managed policy stops at 6,144. Attached alongside the base
# one only when the account holds a cluster, which is also the question the
# access stack asks.
#
# Derived from terraform/aws/managed-cluster, which builds on the community VPC
# and EKS modules, so this is the set those two actually call.
data "aws_iam_policy_document" "cluster" {
  # A cluster gets its own VPC. Creating one names nothing yet, so these cannot
  # be scoped to a resource; the region pin is the only limit that applies.
  statement {
    sid    = "BuildTheClusterNetwork"
    effect = "Allow"
    actions = [
      "ec2:CreateVpc",
      "ec2:CreateSubnet",
      "ec2:CreateRouteTable",
      "ec2:CreateRoute",
      "ec2:CreateInternetGateway",
      "ec2:CreateNatGateway",
      "ec2:CreateVpcEndpoint",
      "ec2:AllocateAddress",
      "ec2:CreateLaunchTemplate",
      "ec2:CreateLaunchTemplateVersion",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = var.regions
    }
  }

  # Changing or removing network the account already had is the risk here, so
  # these apply only to resources carrying our name. The VPC module tags
  # everything it creates, which is what makes the condition hold.
  statement {
    sid    = "ChangeOnlyOurOwnNetwork"
    effect = "Allow"
    actions = [
      "ec2:DeleteVpc",
      "ec2:DeleteSubnet",
      "ec2:DeleteRouteTable",
      "ec2:DeleteRoute",
      "ec2:DeleteInternetGateway",
      "ec2:DeleteNatGateway",
      "ec2:DeleteVpcEndpoint",
      "ec2:ReleaseAddress",
      "ec2:DeleteLaunchTemplate",
      "ec2:DeleteLaunchTemplateVersions",
      "ec2:ModifyVpcAttribute",
      "ec2:ModifySubnetAttribute",
      "ec2:AttachInternetGateway",
      "ec2:DetachInternetGateway",
      "ec2:AssociateRouteTable",
      "ec2:DisassociateRouteTable",
      "ec2:AssociateAddress",
      "ec2:DisassociateAddress",
    ]
    resources = ["*"]

    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/Name"
      values   = ["${var.resource_prefix}*"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = var.regions
    }
  }

  statement {
    sid    = "RunTheCluster"
    effect = "Allow"
    actions = [
      "eks:CreateCluster",
      "eks:DeleteCluster",
      "eks:DescribeCluster",
      "eks:UpdateClusterConfig",
      "eks:UpdateClusterVersion",
      "eks:CreateNodegroup",
      "eks:DeleteNodegroup",
      "eks:DescribeNodegroup",
      "eks:UpdateNodegroupConfig",
      "eks:UpdateNodegroupVersion",
      "eks:CreateAddon",
      "eks:DeleteAddon",
      "eks:DescribeAddon",
      "eks:UpdateAddon",
      "eks:CreateAccessEntry",
      "eks:DeleteAccessEntry",
      "eks:DescribeAccessEntry",
      "eks:AssociateAccessPolicy",
      "eks:DisassociateAccessPolicy",
      "eks:TagResource",
      "eks:UntagResource",
      "eks:ListTagsForResource",
    ]
    resources = [
      "arn:${var.partition}:eks:*:${var.account_id}:cluster/${var.resource_prefix}*",
      "arn:${var.partition}:eks:*:${var.account_id}:nodegroup/${var.resource_prefix}*/*",
      "arn:${var.partition}:eks:*:${var.account_id}:addon/${var.resource_prefix}*/*",
      "arn:${var.partition}:eks:*:${var.account_id}:access-entry/${var.resource_prefix}*/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = var.regions
    }
  }

  # Listing and the add-on catalogue are account-wide reads with no resource to
  # name. Neither says anything but which clusters exist.
  statement {
    sid    = "ReadTheClusterCatalogue"
    effect = "Allow"
    actions = [
      "eks:ListClusters",
      "eks:ListNodegroups",
      "eks:ListAddons",
      "eks:ListAccessEntries",
      "eks:ListAssociatedAccessPolicies",
      "eks:DescribeAddonVersions",
    ]
    resources = ["*"]
  }

  # IRSA. Pods get roles through this provider, so without it every add-on falls
  # back to node credentials. Scoped to providers for EKS clusters.
  statement {
    sid    = "ClusterIdentityProvider"
    effect = "Allow"
    actions = [
      "iam:CreateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:GetOpenIDConnectProvider",
      "iam:TagOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
    ]
    resources = ["arn:${var.partition}:iam::${var.account_id}:oidc-provider/oidc.eks.*.amazonaws.com/id/*"]
  }

  # EKS, node groups and load balancers each want a service-linked role the
  # first time they run in an account. Named, so this creates no others.
  statement {
    sid       = "ServiceLinkedRolesTheClusterNeeds"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:${var.partition}:iam::${var.account_id}:role/aws-service-role/*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "eks.amazonaws.com",
        "eks-nodegroup.amazonaws.com",
        "autoscaling.amazonaws.com",
        "elasticloadbalancing.amazonaws.com",
      ]
    }
  }

  # The control plane encrypts secrets with its own key, and node groups arrive
  # as autoscaling groups Terraform reads back.
  statement {
    sid    = "ClusterKeyAndScaling"
    effect = "Allow"
    actions = [
      "kms:CreateKey",
      "kms:CreateAlias",
      "kms:DeleteAlias",
      "kms:UpdateAlias",
      # An alias has no arn to scope to: the API answers about the account and
      # the caller filters. Reading it back is part of creating one, so every
      # apply fails here without it.
      "kms:ListAliases",
      "kms:ScheduleKeyDeletion",
      "kms:EnableKeyRotation",
      "kms:GetKeyRotationStatus",
      "kms:GetKeyPolicy",
      "kms:PutKeyPolicy",
      "kms:ListResourceTags",
      "kms:TagResource",
      "autoscaling:Describe*",
      "autoscaling:CreateOrUpdateTags",
      "autoscaling:DeleteTags",
      "autoscaling:UpdateAutoScalingGroup",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = var.regions
    }
  }

  # The certificate the load balancer serves. A single machine gets one from
  # Let's Encrypt on the machine; a cluster needs one in ACM, here.
  #
  # Not scoped to a resource: a certificate has no name until it is requested,
  # and its arn is a generated id rather than something we choose.
  statement {
    sid    = "CertificateForTheIngress"
    effect = "Allow"
    actions = [
      "acm:RequestCertificate",
      "acm:DescribeCertificate",
      "acm:DeleteCertificate",
      "acm:ListCertificates",
      "acm:AddTagsToCertificate",
      "acm:ListTagsForCertificate",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = var.regions
    }
  }

  # Reading its own role, which the EKS module does on every plan.
  #
  # It resolves the caller's assumed-role arn back to the role arn behind it,
  # and it does so whether or not the option that uses the answer is on: the
  # data source is gated on the module being created, not on the feature. So
  # this is not optional however the cluster is configured.
  #
  # One role, its own, and a read. The deny above still stops it rewriting
  # itself, which is the thing that mattered.
  dynamic "statement" {
    for_each = var.self_role_name != "" ? [1] : []
    content {
      sid       = "ReadOurOwnRole"
      effect    = "Allow"
      actions   = ["iam:GetRole"]
      resources = ["arn:${var.partition}:iam::${var.account_id}:role/${var.self_role_name}"]
    }
  }

  # Listing log groups is account-wide by design: the API takes a name prefix
  # as a filter, not a resource, so a scoped statement never matches and every
  # apply fails reading back the group it just made. It reveals which log
  # groups exist and nothing in them.
  statement {
    sid       = "FindTheClusterLogGroup"
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = var.regions
    }
  }

  # Control-plane logging, in its own log group named after the cluster.
  statement {
    sid    = "ClusterLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:PutRetentionPolicy",
      "logs:TagResource",
      "logs:ListTagsForResource",
    ]
    resources = ["arn:${var.partition}:logs:*:${var.account_id}:log-group:/aws/eks/${var.resource_prefix}*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = var.regions
    }
  }
}
