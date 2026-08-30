data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# -----------------------------------------------------------------------------
# VPC via the community module
# -----------------------------------------------------------------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${var.name_prefix}-${var.environment}"
  cidr = var.vpc_cidr

  azs             = var.availability_zones
  public_subnets  = var.public_subnet_cidrs
  private_subnets = var.private_subnet_cidrs

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

  enable_cluster_creator_admin_permissions = true

  # Access entries — modern replacement for aws-auth ConfigMap.
  access_entries = {
    for arn in var.operator_admin_arns : arn => {
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
  eks_managed_node_groups = {
    stateful = {
      instance_types = var.stateful_instance_types
      capacity_type  = "ON_DEMAND"
      min_size       = var.stateful_min_size
      desired_size   = var.stateful_desired_size
      max_size       = var.stateful_max_size

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
