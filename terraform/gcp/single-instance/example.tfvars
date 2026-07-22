project_id  = "my-caytu-project"
region      = "us-central1"
zone        = "us-central1-a"
environment = "staging"
name_prefix = "caytu-client"

# --- Instance -----------------------------------------------------------------
machine_type      = "e2-standard-4"
image             = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
boot_disk_size_gb = 100
boot_disk_type    = "pd-balanced"

# Leave ssh_public_key empty for Terraform to generate an ed25519 pair.
ssh_public_key      = ""
ssh_user            = "caytu"
ssh_key_output_path = "./ssh_key.pem"

# --- Networking ---------------------------------------------------------------
network    = "default"
subnetwork = "" # empty = "default"

operator_ssh_cidrs = ["203.0.113.42/32"]  # restrict — do not open :22 to the world
public_http_cidrs  = ["0.0.0.0/0"]

# GCP has no managed WebRTC equivalent to KVS, so self-hosted TURN is the default.
enable_turn_ports  = true

# --- Registry -----------------------------------------------------------------
artifact_repositories = ["backend", "frontend", "webrtc-signaling", "gstreamer-recorder", "mqtt-streamer"]

# --- Backups ------------------------------------------------------------------
create_backup_bucket         = true
backup_bucket_lifecycle_days = 90
backup_bucket_location       = "US"
