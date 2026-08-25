region      = "us-east-1"
aws_profile = "default"
environment = "staging"
name_prefix = "caytu-client"

# --- Instance -----------------------------------------------------------------
instance_type       = "r6g.large" # arm64 Graviton, ~$120/mo
instance_arch       = "arm64"     # "arm64" or "amd64"
root_volume_size_gb = 100

# Leave ssh_public_key empty to have Terraform generate an ed25519 key pair.
# The private key lands at ssh_key_output_path.
ssh_public_key      = ""
ssh_key_output_path = "./ssh_key.pem"

# --- Networking ---------------------------------------------------------------
# Restrict SSH to your operator IPs — DO NOT leave this open.
operator_ssh_cidrs = ["203.0.113.42/32"]
public_http_cidrs  = ["0.0.0.0/0"]

# Only needed if STREAMING_PROVIDER=self-hosted (i.e. you overrode the AWS
# defaults). Leave false for the standard AWS + KVS path.
enable_turn_ports = false

# --- DNS ----------------------------------------------------------------------
# Off by default. Turn on to have Terraform create an A record pointing your
# domain at the instance's Elastic IP — the CLI then bootstraps Let's Encrypt
# automatically at the end of `caytu-client aws provision`.
enable_route53 = false
# route53_zone_name = "caytu.link"          # hosted zone you already own
# domain_name       = "client.caytu.link"   # FQDN for this instance
# letsencrypt_email = "ops@caytu.com"       # required for automatic TLS

# Set true only for a brand-new domain with no hosted zone yet. You must then
# point your registrar at the `route53_nameservers` output before TLS can work.
# create_route53_zone     = false
# route53_record_ttl      = 60
# route53_allow_overwrite = false           # true to adopt an existing record

# --- Registry -----------------------------------------------------------------
ecr_repositories = ["backend", "frontend", "webrtc-signaling", "gstreamer-recorder", "mqtt-streamer"]

# --- Backups ------------------------------------------------------------------
create_backup_bucket         = true
backup_bucket_lifecycle_days = 90

# --- IoT ----------------------------------------------------------------------
enable_iot                 = true
iot_role_alias_ttl_seconds = 3600

# --- Deploying into an account we do not own ----------------------------------
# All empty on a Caytu-hosted apply, which is the default behaviour.
# The customer creates these by running terraform/aws/customer-onboarding once.
assume_role_arn          = ""
assume_role_external_id  = ""
iam_permissions_boundary = ""

# No SSH key at all. Session Manager is already on the instance role, and a
# generated key would otherwise sit in Terraform state forever.
create_ssh_key_pair = true

# Route 53 runs through its own provider, so the name can stay in Caytu's
# account while the machine lives in the customer's.
dns_assume_role_arn = ""
dns_region          = "us-east-1"
