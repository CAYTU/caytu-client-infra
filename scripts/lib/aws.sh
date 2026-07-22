# shellcheck shell=bash
# AWS lifecycle helpers driven by the caytu-client CLI. Reads/writes CLI state,
# runs Terraform under terraform/aws/single-instance/, wraps aws-cli for
# instance start/stop/resize/security-group updates.

# All AWS lib functions assume the CLI has set:
#   REPO_ROOT   → path to caytu-client-infra checkout
#   TARGET      → aws-single (this lib only handles single-instance for phase 2)
#   COMPOSE_DIR → $REPO_ROOT/compose
# and sourced common.sh + ssh.sh before this file.

_aws_tf_dir() { printf '%s/terraform/aws/single-instance\n' "$REPO_ROOT"; }

_aws_profile() {
  # Priority: state → env file → default
  local p
  p="$(state_get aws_profile)"; [[ -n "$p" ]] && { echo "$p"; return; }
  p="$(env_get "$(env_file_for)" AWS_PROFILE 2>/dev/null || true)"; [[ -n "$p" ]] && { echo "$p"; return; }
  echo "default"
}

_aws_region() {
  local r
  r="$(state_get aws_region)"; [[ -n "$r" ]] && { echo "$r"; return; }
  r="$(env_get "$(env_file_for)" AWS_REGION 2>/dev/null || true)"; [[ -n "$r" ]] && { echo "$r"; return; }
  echo "us-east-1"
}

_aws() {
  aws --profile "$(_aws_profile)" --region "$(_aws_region)" "$@"
}

# Copy outputs from a Terraform apply into CLI state + .env.aws-single so all
# subsequent verbs (ssh, env push, ecr-login, etc.) just work.
_aws_load_outputs() {
  local tf_dir env_file
  tf_dir="$(_aws_tf_dir)"
  env_file="$(env_file_for)"

  local outputs
  outputs="$(cd "$tf_dir" && terraform output -json)" || die "terraform output failed"

  local ip user key sg region ecr restic iot_ep iot_alias
  ip="$(       jq -r '.public_ip.value'                        <<<"$outputs")"
  user="$(     jq -r '.ssh_user.value'                         <<<"$outputs")"
  key="$(      jq -r '.ssh_key_path.value // empty'            <<<"$outputs")"
  sg="$(       jq -r '.security_group_id.value'                <<<"$outputs")"
  region="$(   jq -r '.region.value'                           <<<"$outputs")"
  ecr="$(      jq -r '.ecr_registry.value'                     <<<"$outputs")"
  restic="$(   jq -r '.restic_repository.value // empty'       <<<"$outputs")"
  iot_ep="$(   jq -r '.iot_data_endpoint.value // empty'       <<<"$outputs")"
  iot_alias="$(jq -r '.iot_role_alias.value // empty'          <<<"$outputs")"

  # State: enough for the SSH path
  state_set ssh_host "$ip"
  state_set ssh_user "$user"
  [[ -n "$key" ]] && state_set ssh_key_path "$(cd "$tf_dir" && readlink -f "$key")"
  state_set security_group_id "$sg"
  state_set aws_region "$region"
  state_set instance_id "$(jq -r '.instance_id.value' <<<"$outputs")"

  # Env file — only patch if the values are still their .env.example defaults.
  # We refuse to clobber operator edits.
  _aws_env_patch "$env_file" IMAGE_REGISTRY  "$ecr"
  [[ -n "$restic"   ]] && _aws_env_patch "$env_file" RESTIC_REPOSITORY "$restic"
  [[ -n "$iot_ep"   ]] && _aws_env_patch "$env_file" AWS_IOT_ENDPOINT  "$iot_ep"
  [[ -n "$iot_alias" ]] && _aws_env_patch "$env_file" AWS_IOT_ROLE_ALIAS "$iot_alias"
  _aws_env_patch "$env_file" AWS_REGION "$region"
  _aws_env_patch "$env_file" STREAMING_PROVIDER kvs

  ok "wrote state + patched $env_file with Terraform outputs"
}

# Sets KEY=VALUE in the env file, adding it if missing. Skips if the current
# value is non-empty AND different from what we're about to write (respects
# operator overrides — you can force with FORCE=1).
_aws_env_patch() {
  local file=$1 key=$2 value=$3
  [[ -f "$file" ]] || { warn "$file missing; skipping $key"; return; }

  local current
  current="$(env_get "$file" "$key" 2>/dev/null || true)"
  if [[ -n "$current" && "$current" != "$value" && "${FORCE:-}" != "1" ]]; then
    if [[ "$current" == "example.com" || "$current" == "self-hosted" || "$current" == "us-east-1" ]]; then
      : # placeholder defaults from .env.example — overwrite is fine
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

aws_doctor() {
  require_cmd aws terraform jq
  local p; p="$(_aws_profile)"
  if _aws sts get-caller-identity >/dev/null 2>&1; then
    ok "aws sts get-caller-identity via profile '$p' ($(_aws_region))"
  else
    warn "aws sts get-caller-identity FAILED for profile '$p' — run 'aws sso login' or fix credentials"
  fi
}

aws_provision() {
  require_cmd terraform aws jq
  local tf_dir; tf_dir="$(_aws_tf_dir)"
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

  _aws_load_outputs
  ok "provision complete. Next: caytu-client -t aws-single env push && caytu-client -t aws-single up"
}

aws_destroy() {
  require_cmd terraform
  local tf_dir; tf_dir="$(_aws_tf_dir)"
  confirm "This will destroy the EC2 instance, EIP, security group, and ECR repos. Continue?" || return 0
  (cd "$tf_dir" && terraform destroy "$@")

  # Clean the SSH-related state so a fresh provision starts clean
  for k in ssh_host security_group_id instance_id; do
    state_set "$k" ""
  done
  ok "destroyed"
}

aws_instance() {
  local sub=${1:-info}; shift || true
  local iid; iid="$(state_get instance_id)"
  [[ -n "$iid" ]] || die "no instance_id in state — run 'caytu-client aws provision' first"

  case "$sub" in
    start)
      info "starting $iid…"
      _aws ec2 start-instances --instance-ids "$iid" >/dev/null
      _aws ec2 wait instance-running --instance-ids "$iid"
      ok "running"
      # EIP might have been reassigned during stop/start — refresh outputs
      (cd "$(_aws_tf_dir)" && terraform refresh >/dev/null 2>&1) || true
      _aws_load_outputs ;;
    stop)
      info "stopping $iid…"
      _aws ec2 stop-instances --instance-ids "$iid" >/dev/null
      _aws ec2 wait instance-stopped --instance-ids "$iid"
      ok "stopped" ;;
    info)
      _aws ec2 describe-instances --instance-ids "$iid" \
        --query 'Reservations[0].Instances[0].{State:State.Name,Type:InstanceType,PublicIp:PublicIpAddress,PrivateIp:PrivateIpAddress,Launch:LaunchTime,AZ:Placement.AvailabilityZone}' \
        --output table ;;
    resize)
      local new_type=${1:-}
      [[ -n "$new_type" ]] || die "usage: aws instance resize <type>"
      confirm "This stops the instance, changes to $new_type, and starts it. Continue?" || return 0
      _aws ec2 stop-instances --instance-ids "$iid" >/dev/null
      _aws ec2 wait instance-stopped --instance-ids "$iid"
      _aws ec2 modify-instance-attribute --instance-id "$iid" --instance-type "Value=$new_type"
      _aws ec2 start-instances --instance-ids "$iid" >/dev/null
      _aws ec2 wait instance-running --instance-ids "$iid"
      ok "resized to $new_type" ;;
    *) die "usage: caytu-client aws instance <start|stop|info|resize <type>>" ;;
  esac
}

aws_ecr_login() {
  require_cmd aws docker
  local reg
  reg="$(env_get "$(env_file_for)" IMAGE_REGISTRY 2>/dev/null || true)"
  [[ -n "$reg" ]] || die "IMAGE_REGISTRY not set in $(env_file_for) — run 'caytu-client aws provision' first"

  info "docker login $reg…"
  _aws ecr get-login-password | docker login --username AWS --password-stdin "$reg"
  ok "logged in"

  # Also push the login to the remote host so `docker compose pull` works there
  case "$TARGET" in
    aws-single|ssh)
      local host; host="$(ssh_host || true)"
      if [[ -n "$host" ]]; then
        info "propagating login to $host…"
        _aws ecr get-login-password | ssh_run "docker login --username AWS --password-stdin $reg"
        ok "remote logged in"
      fi ;;
  esac
}

# Refresh THIS laptop's public IP in the security group's SSH rule. Handy when
# you're on a coffee-shop wifi.
aws_allow_me() {
  local sg; sg="$(state_get security_group_id)"
  [[ -n "$sg" ]] || die "no security_group_id in state — run provision first"

  local ip
  ip="$(curl -fsS4 https://checkip.amazonaws.com/ | tr -d '[:space:]')"
  [[ -n "$ip" ]] || die "could not determine public IP"

  info "authorizing $ip/32 on sg $sg port 22…"
  _aws ec2 authorize-security-group-ingress \
    --group-id "$sg" \
    --protocol tcp \
    --port 22 \
    --cidr "$ip/32" 2>/dev/null && ok "added" || warn "rule may already exist"
}
