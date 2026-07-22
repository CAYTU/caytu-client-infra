# shellcheck shell=bash
# GCP lifecycle helpers driven by the caytu-client CLI.
# Mirrors scripts/lib/aws.sh where sensible so operators can move between clouds
# with the same muscle memory.

_gcp_tf_dir() { printf '%s/terraform/gcp/single-instance\n' "$REPO_ROOT"; }

_gcp_project() {
  local p
  p="$(state_get gcp_project)"; [[ -n "$p" ]] && { echo "$p"; return; }
  p="$(env_get "$(env_file_for)" GCP_PROJECT_ID 2>/dev/null || true)"; [[ -n "$p" ]] && { echo "$p"; return; }
  gcloud config get-value project 2>/dev/null | grep -v '^$' | head -1
}

_gcp_zone() {
  local z
  z="$(state_get gcp_zone)"; [[ -n "$z" ]] && { echo "$z"; return; }
  echo "us-central1-a"
}

_gcloud() {
  gcloud --project "$(_gcp_project)" "$@"
}

_gcp_load_outputs() {
  local tf_dir env_file
  tf_dir="$(_gcp_tf_dir)"
  env_file="$(env_file_for)"

  local outputs
  outputs="$(cd "$tf_dir" && terraform output -json)" || die "terraform output failed"

  local ip user key project region zone instance registry restic
  ip="$(       jq -r '.public_ip.value'                      <<<"$outputs")"
  user="$(     jq -r '.ssh_user.value'                       <<<"$outputs")"
  key="$(      jq -r '.ssh_key_path.value // empty'          <<<"$outputs")"
  project="$(  jq -r '.project_id.value'                     <<<"$outputs")"
  region="$(   jq -r '.region.value'                         <<<"$outputs")"
  zone="$(     jq -r '.instance_zone.value'                  <<<"$outputs")"
  instance="$( jq -r '.instance_name.value'                  <<<"$outputs")"
  registry="$( jq -r '.image_registry.value'                 <<<"$outputs")"
  restic="$(   jq -r '.restic_repository.value // empty'     <<<"$outputs")"

  state_set ssh_host "$ip"
  state_set ssh_user "$user"
  [[ -n "$key" ]] && state_set ssh_key_path "$(cd "$tf_dir" && readlink -f "$key")"
  state_set gcp_project "$project"
  state_set gcp_region "$region"
  state_set gcp_zone "$zone"
  state_set gcp_instance "$instance"

  _gcp_env_patch "$env_file" IMAGE_REGISTRY   "$registry"
  [[ -n "$restic" ]] && _gcp_env_patch "$env_file" RESTIC_REPOSITORY "$restic"
  _gcp_env_patch "$env_file" AWS_REGION "" # clear AWS vars if present
  _gcp_env_patch "$env_file" STREAMING_PROVIDER self-hosted

  ok "wrote state + patched $env_file with Terraform outputs"
}

_gcp_env_patch() {
  local file=$1 key=$2 value=$3
  [[ -f "$file" ]] || { warn "$file missing; skipping $key"; return; }

  local current
  current="$(env_get "$file" "$key" 2>/dev/null || true)"
  if [[ -n "$current" && "$current" != "$value" && "${FORCE:-}" != "1" ]]; then
    if [[ "$current" == "example.com" || "$current" == "self-hosted" || "$current" == "us-east-1" ]]; then
      : # placeholder → overwrite fine
    else
      warn "keeping $key=$current (Terraform wanted: $value; set FORCE=1 to override)"
      return
    fi
  fi

  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$file"
  fi
}

# ---------- verbs -----------------------------------------------------------

gcp_doctor() {
  require_cmd gcloud terraform jq
  local project; project="$(_gcp_project)"
  [[ -n "$project" ]] || warn "no active GCP project — 'gcloud config set project <id>'"
  if _gcloud auth list --filter=status:ACTIVE --format='value(account)' | grep -q .; then
    ok "gcloud authenticated as $(_gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -1)"
  else
    warn "gcloud not authenticated — run 'gcloud auth login' AND 'gcloud auth application-default login'"
  fi
}

gcp_provision() {
  require_cmd terraform gcloud jq
  local tf_dir; tf_dir="$(_gcp_tf_dir)"
  local tfvars="$tf_dir/terraform.tfvars"

  if [[ ! -f "$tfvars" ]]; then
    info "no terraform.tfvars; copying from example (edit before continuing)"
    cp "$tf_dir/example.tfvars" "$tfvars"
    $EDITOR "$tfvars"
  fi

  info "terraform init…"
  (cd "$tf_dir" && terraform init -upgrade)
  info "terraform apply…"
  (cd "$tf_dir" && terraform apply "$@")

  _gcp_load_outputs
  ok "provision complete. Next: caytu-client -t gcp-single env push && caytu-client -t gcp-single up"
}

gcp_destroy() {
  require_cmd terraform
  local tf_dir; tf_dir="$(_gcp_tf_dir)"
  confirm "This will destroy the VM, static IP, firewall rules, Artifact Registry, service account. Continue?" || return 0
  (cd "$tf_dir" && terraform destroy "$@")

  for k in ssh_host gcp_instance; do
    state_set "$k" ""
  done
  ok "destroyed"
}

gcp_instance() {
  local sub=${1:-info}; shift || true
  local name zone project
  name="$(state_get gcp_instance)"
  zone="$(_gcp_zone)"
  project="$(_gcp_project)"
  [[ -n "$name" ]] || die "no gcp_instance in state — run 'caytu-client gcp provision' first"

  case "$sub" in
    start)
      info "starting $name…"
      _gcloud compute instances start "$name" --zone "$zone" --quiet
      ok "running"
      # public IP is static — no refresh needed
      ;;
    stop)
      info "stopping $name…"
      _gcloud compute instances stop "$name" --zone "$zone" --quiet
      ok "stopped" ;;
    info)
      _gcloud compute instances describe "$name" --zone "$zone" \
        --format='table(name,status,machineType.basename(),networkInterfaces[0].accessConfigs[0].natIP,creationTimestamp)' ;;
    resize)
      local new_type=${1:-}
      [[ -n "$new_type" ]] || die "usage: gcp instance resize <machine-type>"
      confirm "This stops the VM, changes to $new_type, and starts it. Continue?" || return 0
      _gcloud compute instances stop "$name" --zone "$zone" --quiet
      _gcloud compute instances set-machine-type "$name" --zone "$zone" --machine-type "$new_type"
      _gcloud compute instances start "$name" --zone "$zone" --quiet
      ok "resized to $new_type" ;;
    *) die "usage: caytu-client gcp instance <start|stop|info|resize <type>>" ;;
  esac
}

# Docker login to Artifact Registry — the CLI helper uses application-default
# credentials; on the instance the attached service account already gives
# artifactregistry.reader, so no login is needed there.
gcp_registry_login() {
  require_cmd gcloud docker
  local region; region="$(state_get gcp_region)"; [[ -z "$region" ]] && region="us-central1"
  info "docker login ${region}-docker.pkg.dev…"
  _gcloud auth configure-docker "${region}-docker.pkg.dev" --quiet
  ok "docker credentialed for Artifact Registry"
}

gcp_allow_me() {
  require_cmd gcloud
  local ip
  ip="$(curl -fsS4 https://checkip.amazonaws.com/ | tr -d '[:space:]')"
  [[ -n "$ip" ]] || die "could not determine public IP"

  local rule="caytu-client-$(state_get gcp_project | tr '.' '-')-me"
  # GCP firewall rules are on the network, not per-instance — we tag-target ours.
  # Add a per-operator rule; delete on next run.
  local tag; tag="$(state_get gcp_instance)"
  [[ -n "$tag" ]] || die "no gcp_instance in state"

  info "authorizing $ip/32 to tag $tag on port 22…"
  _gcloud compute firewall-rules delete "$rule" --quiet 2>/dev/null || true
  _gcloud compute firewall-rules create "$rule" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:22 \
    --source-ranges="$ip/32" \
    --target-tags="$tag"
  ok "authorized"
}
