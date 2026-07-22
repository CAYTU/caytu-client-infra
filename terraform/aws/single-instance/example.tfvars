region        = "us-east-1"
aws_profile   = "default"
environment   = "staging"
name_prefix   = "caytu-client"

# --- Instance -----------------------------------------------------------------
instance_type       = "r6g.large"     # arm64 Graviton, ~$120/mo
instance_arch       = "arm64"         # "arm64" or "amd64"
root_volume_size_gb = 100

# Leave ssh_public_key empty to have Terraform generate an ed25519 key pair.
# The private key lands at ssh_key_output_path.
ssh_public_key       = ""
ssh_key_output_path  = "./ssh_key.pem"

# --- Networking ---------------------------------------------------------------
# Restrict SSH to your operator IPs — DO NOT leave this open.
operator_ssh_cidrs   = ["203.0.113.42/32"]
public_http_cidrs    = ["0.0.0.0/0"]

# Only needed if STREAMING_PROVIDER=self-hosted (i.e. you overrode the AWS
# defaults). Leave false for the standard AWS + KVS path.
enable_turn_ports    = false

# --- Registry -----------------------------------------------------------------
ecr_repositories = ["backend", "frontend", "webrtc-signaling", "gstreamer-recorder", "mqtt-streamer"]

# --- Backups ------------------------------------------------------------------
create_backup_bucket         = true
backup_bucket_lifecycle_days = 90

# --- IoT ----------------------------------------------------------------------
enable_iot                   = true
iot_role_alias_ttl_seconds   = 3600
