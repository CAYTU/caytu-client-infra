project_id  = "my-caytu-project"
region      = "us-central1"
environment = "staging"
name_prefix = "caytu-client"

cluster_version = "1.30"

# --- Cluster shape ------------------------------------------------------------
regional          = false            # true = HA control plane (regional), false = zonal (cheaper)
zone              = "us-central1-a"  # ignored when regional=true
node_machine_type = "e2-standard-2"
node_count        = 3
node_min_count    = 3
node_max_count    = 10
node_preemptible  = false            # true for staging cost savings

# --- Network ------------------------------------------------------------------
network_cidr  = "10.70.0.0/16"
pods_cidr     = "10.71.0.0/16"
services_cidr = "10.72.0.0/20"

# --- Artifact Registry / GCS --------------------------------------------------
artifact_repositories        = ["backend", "frontend", "webrtc-signaling", "gstreamer-recorder", "mqtt-streamer"]
create_backup_bucket         = true
backup_bucket_location       = "US"
