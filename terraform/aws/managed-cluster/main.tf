data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# Asked of the region rather than written down. The list was pinned to
# us-east-1a/b/c and nothing overrode it, so a cluster in Frankfurt or Cape Town
# would have tried to build subnets in zones that region does not have.
data "aws_availability_zones" "available" {
  state = "available"

  # Local zones and Wavelength zones are in the same list and cannot run EKS
  # nodes, so a region with one would otherwise hand us an unusable zone.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  # Who administers this cluster.
  #
  # Named rather than inferred. The module's own option asks IAM who the caller
  # is, which needs iam:GetRole on the role it is already running as, and the
  # provisioner role deliberately cannot read IAM. Granting that permission to
  # satisfy a lookup would be widening the role to answer a question we can
  # already answer.
  #
  # It is also the better shape: the cluster's administrator should be a
  # principal we chose, not a consequence of whoever happened to run the apply.
  #
  # Building in someone else's account means the role we assumed. In our own it
  # is the role this run holds, which arrives as an assumed-role arn and has to
  # be turned back into the role arn an access entry wants.
  caller_arn             = data.aws_caller_identity.current.arn
  caller_is_assumed_role = can(regex(":assumed-role/", local.caller_arn))
  caller_role_name       = local.caller_is_assumed_role ? split("/", local.caller_arn)[1] : ""
  own_role_arn           = local.caller_is_assumed_role ? "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.caller_role_name}" : local.caller_arn

  creator_admin_arn = var.assume_role_arn != "" ? var.assume_role_arn : local.own_role_arn

  # The operators named in tfvars, plus whoever is applying. Deduplicated, or
  # naming the applying role in tfvars too would produce a duplicate key.
  cluster_admin_arns = distinct(concat(var.operator_admin_arns, [local.creator_admin_arn]))

  # Three where a region has three, fewer where it does not. `slice` past the
  # end is an error, not a shorter list.
  discovered_azs = slice(
    data.aws_availability_zones.available.names,
    0,
    min(3, length(data.aws_availability_zones.available.names))
  )
  availability_zones = length(var.availability_zones) > 0 ? var.availability_zones : local.discovered_azs

  # The module pairs subnets to zones by position, so the lists have to be the
  # same length or it fails with an index error rather than anything readable.
  az_count        = length(local.availability_zones)
  public_subnets  = slice(var.public_subnet_cidrs, 0, min(local.az_count, length(var.public_subnet_cidrs)))
  private_subnets = slice(var.private_subnet_cidrs, 0, min(local.az_count, length(var.private_subnet_cidrs)))
}

# -----------------------------------------------------------------------------
# VPC via the community module
# -----------------------------------------------------------------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${var.name_prefix}-${var.environment}"
  cidr = var.vpc_cidr

  azs             = local.availability_zones
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  # Left as AWS made them. Tightening the default ACL and security group means
  # editing resources we did not create, which needs network-ACL permissions
  # across the account, and the tag condition that would scope them is not
  # reliably set at the moment the call is made. Nothing is attached to either:
  # the cluster brings its own security groups.
  manage_default_network_acl    = false
  manage_default_security_group = false
  manage_default_route_table    = false

  enable_nat_gateway   = true
  single_nat_gateway   = true # one NAT keeps costs down for staging; set false for prod
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Tags required by AWS Load Balancer Controller for subnet discovery
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# -----------------------------------------------------------------------------
# EKS via the community module
# -----------------------------------------------------------------------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.20"

  cluster_name    = "${var.name_prefix}-${var.environment}"
  cluster_version = var.cluster_version

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"] # restrict via operator_ssh_cidrs equivalent in prod

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Every role the module creates has to carry the boundary and start with our
  # name. A customer's policy refuses CreateRole without the boundary outright,
  # and only allows it for names beginning caytu-, so the module's own defaults
  # fail twice over: unbounded, and named after the node group.
  iam_role_permissions_boundary = var.iam_permissions_boundary != "" ? var.iam_permissions_boundary : null

  # Off, because it resolves the creator by asking IAM. See cluster_admin_arns:
  # the applying role is added to the access entries below by name instead.
  enable_cluster_creator_admin_permissions = false

  # Access entries — modern replacement for aws-auth ConfigMap.
  access_entries = {
    for arn in local.cluster_admin_arns : arn => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = {}
    aws-ebs-csi-driver = {
      service_account_role_arn = aws_iam_role.ebs_csi.arn
    }
  }

  # Two node groups:
  #
  #   stateful   → on-demand. Holds MongoDB/Redis/MinIO/gstreamer-recorder —
  #                anything with an EBS PVC. Sudden termination = data-plane
  #                impact, so we pay a bit more for lifecycle stability.
  #
  #   stateless  → SPOT. Holds backend/frontend/signaling/mqtt-streamer. ~70%
  #                cheaper than on-demand. On reclamation kubernetes reschedules
  #                the pod within seconds (PDB + topology spread already in
  #                place from the perf pass). AWS gives a 2-minute warning.
  #
  # Kustomize aws-eks overlay adds nodeSelector: caytu.io/workload=stateful
  # to the stateful workloads. Stateless deployments have no selector and land
  # on whichever pool has room (typically SPOT since it's the bigger pool).
  eks_managed_node_group_defaults = {
    iam_role_permissions_boundary = var.iam_permissions_boundary != "" ? var.iam_permissions_boundary : null
    # Without this the role is named after the node group, e.g.
    # "stateful-eks-node-group-", which a customer's policy does not recognise
    # as ours and refuses to create.
    iam_role_name            = null
    iam_role_use_name_prefix = true
  }

  eks_managed_node_groups = {
    stateful = {
      instance_types = var.stateful_instance_types
      capacity_type  = "ON_DEMAND"
      min_size       = var.stateful_min_size
      desired_size   = var.stateful_desired_size
      max_size       = var.stateful_max_size

      iam_role_name = "${var.name_prefix}-stateful-node"

      labels = { "caytu.io/workload" = "stateful" }

      tags = {
        "k8s.io/cluster-autoscaler/enabled"                               = "true"
        "k8s.io/cluster-autoscaler/${var.name_prefix}-${var.environment}" = "owned"
      }

      iam_role_additional_policies = {
        AmazonEBSCSIDriverPolicy = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
      }
    }

    stateless = {
      # Multiple types diversifies SPOT: AWS substitutes if one type is
      # unavailable in your AZ. Keep them same-size or the HPA behavior gets
      # unpredictable.
      instance_types = var.stateless_instance_types
      capacity_type  = "SPOT"
      min_size       = var.stateless_min_size
      desired_size   = var.stateless_desired_size
      max_size       = var.stateless_max_size

      iam_role_name = "${var.name_prefix}-stateless-node"

      labels = { "caytu.io/workload" = "stateless" }

      tags = {
        "k8s.io/cluster-autoscaler/enabled"                               = "true"
        "k8s.io/cluster-autoscaler/${var.name_prefix}-${var.environment}" = "owned"
      }

      iam_role_additional_policies = {
        AmazonEBSCSIDriverPolicy = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
      }
    }
  }
}

# -----------------------------------------------------------------------------
# gp3 storage class (base assumes gp3; the addon's default is gp2)
# -----------------------------------------------------------------------------
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type   = "gp3"
    fsType = "ext4"
  }

  depends_on = [module.eks]
}

# -----------------------------------------------------------------------------
# gp2 -> not default anymore
# -----------------------------------------------------------------------------
resource "kubernetes_annotations" "gp2_not_default" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata {
    name = "gp2"
  }
  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }
  force = true

  depends_on = [module.eks]
}
