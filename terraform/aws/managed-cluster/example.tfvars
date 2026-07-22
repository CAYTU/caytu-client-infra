region      = "us-east-1"
aws_profile = "default"
environment = "staging"
name_prefix = "caytu-client"

cluster_version = "1.30"

# --- VPC ----------------------------------------------------------------------
vpc_cidr             = "10.60.0.0/16"
availability_zones   = ["us-east-1a", "us-east-1b", "us-east-1c"]
public_subnet_cidrs  = ["10.60.101.0/24", "10.60.102.0/24", "10.60.103.0/24"]
private_subnet_cidrs = ["10.60.1.0/24",   "10.60.2.0/24",   "10.60.3.0/24"]

# --- Node pools ---------------------------------------------------------------
# Stateful pool — hosts MongoDB/Redis/MinIO/gstreamer-recorder (EBS-anchored).
# Stays on-demand so a SPOT reclamation doesn't strand the data plane.
stateful_instance_types = ["m6i.large"]
stateful_min_size       = 2
stateful_desired_size   = 2
stateful_max_size       = 3

# Stateless pool — hosts backend/frontend/signaling/mqtt-streamer. SPOT is
# ~70% cheaper than on-demand. Diversified type list lets AWS substitute if
# one type is unavailable. HPA + PDB + topology spread from the perf pass
# handles the eviction resilience.
stateless_instance_types = ["m6i.large", "m5.large", "m5a.large", "m5n.large"]
stateless_min_size       = 2
stateless_desired_size   = 3
stateless_max_size       = 10

# IAM ARNs to grant cluster-admin (e.g. your SSO role)
operator_admin_arns = ["arn:aws:iam::123456789012:role/AWSReservedSSO_AdministratorAccess_deadbeef"]

# --- ECR / IoT / S3 -----------------------------------------------------------
ecr_repositories             = ["backend", "frontend", "gstreamer-recorder", "mqtt-streamer"]
enable_iot                   = true
iot_role_alias_ttl_seconds   = 3600
create_backup_bucket         = true
