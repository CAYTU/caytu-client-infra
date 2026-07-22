project_id  = "my-caytu-project"
region      = "us-central1"
environment = "staging"
name_prefix = "caytu-client"

cluster_version = "1.30"

# --- Cluster shape ------------------------------------------------------------
regional = false            # true = HA control plane (regional), false = zonal (cheaper)
zone     = "us-central1-a"  # ignored when regional=true

# Stateful pool — hosts MongoDB/Redis/MinIO/gstreamer-recorder.
# Always on-demand — sudden reclamation would strand the data plane.
stateful_machine_type = "e2-standard-4"
stateful_node_count   = 2
stateful_min_count    = 2
stateful_max_count    = 3

# Stateless pool — hosts backend/frontend/signaling/mqtt-streamer.
# Spot VMs are ~60-91% cheaper than on-demand and don't have preemptible's
# 24h lifetime cap. HPA + PDB + topology spread from the perf pass handle
# eviction gracefully.
stateless_machine_type = "e2-standard-2"
stateless_node_count   = 2
stateless_min_count    = 2
stateless_max_count    = 10
stateless_use_spot     = true

# --- Network ------------------------------------------------------------------
network_cidr  = "10.70.0.0/16"
pods_cidr     = "10.71.0.0/16"
services_cidr = "10.72.0.0/20"

# --- Artifact Registry / GCS --------------------------------------------------
artifact_repositories        = ["backend", "frontend", "webrtc-signaling", "gstreamer-recorder", "mqtt-streamer"]
create_backup_bucket         = true
backup_bucket_location       = "US"
