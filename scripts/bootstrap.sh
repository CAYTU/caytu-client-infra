#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — one-shot host bootstrap for Ubuntu/Debian
#
#   # Docker compose stack host (default):
#   curl -fsSL https://raw.githubusercontent.com/CAYTU/caytu-client-infra/main/scripts/bootstrap.sh | sudo bash
#
#   # Single-node k3s cluster:
#   curl -fsSL https://raw.githubusercontent.com/CAYTU/caytu-client-infra/main/scripts/bootstrap.sh \
#     | sudo INSTALL_K3S=1 bash
#
#   # Join an existing k3s cluster:
#   curl -fsSL https://raw.githubusercontent.com/CAYTU/caytu-client-infra/main/scripts/bootstrap.sh \
#     | sudo INSTALL_K3S=1 K3S_URL=https://<server>:6443 K3S_TOKEN=<token> bash
#
# Idempotent — safe to re-run.
# =============================================================================

set -Eeuo pipefail

: "${DEPLOY_DIR:=/opt/caytu-client}"
: "${DEPLOY_USER:=${SUDO_USER:-$USER}}"
: "${INSTALL_K3S:=0}"

log() { printf "[bootstrap] %s\n" "$*" >&2; }

if [[ $EUID -ne 0 ]]; then
  log "must be run as root (or via sudo)"; exit 1
fi

log "updating apt cache"
apt-get update -y

log "installing base packages"
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg lsb-release rsync jq unzip

if ! command -v docker >/dev/null 2>&1; then
  log "installing docker engine"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/${ID:-ubuntu} ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
else
  log "docker already installed: $(docker --version)"
fi

log "adding $DEPLOY_USER to docker group"
usermod -aG docker "$DEPLOY_USER" || true

# Optional: awscli for ECR login and terraform-heavy work
if ! command -v aws >/dev/null 2>&1; then
  log "installing aws cli v2"
  arch="$(uname -m)"
  case "$arch" in
    x86_64) awszip="awscli-exe-linux-x86_64.zip" ;;
    aarch64) awszip="awscli-exe-linux-aarch64.zip" ;;
    *) log "unknown arch $arch — skipping awscli"; awszip="" ;;
  esac
  if [[ -n "$awszip" ]]; then
    tmp=$(mktemp -d)
    (cd "$tmp" && curl -fsSLO "https://awscli.amazonaws.com/$awszip" && unzip -q "$awszip" && ./aws/install)
    rm -rf "$tmp"
  fi
fi

log "preparing deploy dir $DEPLOY_DIR"
mkdir -p "$DEPLOY_DIR/compose" "$DEPLOY_DIR/backups"
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_DIR"

# -----------------------------------------------------------------------------
# Optional: k3s single-node or join
# -----------------------------------------------------------------------------
if [[ "$INSTALL_K3S" == "1" ]]; then
  if command -v k3s >/dev/null 2>&1; then
    log "k3s already installed: $(k3s --version | head -1)"
  else
    if [[ -n "${K3S_URL:-}" && -n "${K3S_TOKEN:-}" ]]; then
      log "joining existing k3s cluster at $K3S_URL"
      curl -sfL https://get.k3s.io | K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" sh -
    else
      # Single-node server. --write-kubeconfig-mode 644 lets non-root read it.
      # --disable traefik because we prefer nginx-ingress (base assumes it).
      log "installing single-node k3s server"
      curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --write-kubeconfig-mode 644 --disable traefik" sh -
    fi
    log "k3s installed"
  fi

  # Make kubeconfig accessible to the deploy user (server-node only)
  if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
    mkdir -p "/home/$DEPLOY_USER/.kube"
    cp /etc/rancher/k3s/k3s.yaml "/home/$DEPLOY_USER/.kube/config"
    chown -R "$DEPLOY_USER:$DEPLOY_USER" "/home/$DEPLOY_USER/.kube"
    chmod 600 "/home/$DEPLOY_USER/.kube/config"
    log "kubeconfig written to /home/$DEPLOY_USER/.kube/config"

    # Print the node token so operators can add workers
    if [[ -f /var/lib/rancher/k3s/server/node-token ]]; then
      log ""
      log "To add worker nodes, on each worker run:"
      log "  curl -fsSL https://raw.githubusercontent.com/CAYTU/caytu-client-infra/main/scripts/bootstrap.sh | \\"
      log "    sudo INSTALL_K3S=1 K3S_URL=https://$(hostname -I | awk '{print $1}'):6443 \\"
      log "    K3S_TOKEN=$(cat /var/lib/rancher/k3s/server/node-token) bash"
    fi
  fi

  log ""
  log "next steps (from your workstation):"
  log "  # copy the kubeconfig locally"
  log "  scp $DEPLOY_USER@$(hostname -I | awk '{print $1}'):~/.kube/config ~/.kube/caytu-cluster"
  log "  export KUBECONFIG=~/.kube/caytu-cluster"
  log "  # install nginx-ingress cluster-wide (one time)"
  log "  helm install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace"
  log "  # deploy the app"
  log "  cd kubernetes/overlays/self-managed && cp secrets.env.example secrets.env && \$EDITOR secrets.env"
  log "  kubectl apply -k ."
elif [[ -n "${CAYTU_INSTANCE_ID:-}" ]]; then
  # A machine we provisioned. It finishes on its own from here: nobody is
  # watching, and the point of Caytu hosted is that the customer never touches
  # the box.
  #
  # No credential arrives with it. It proves what it is with the identity
  # document AWS signs for every instance, which is why user_data carries only
  # these two values, neither of them secret.
  log "Caytu-hosted instance for deployment $CAYTU_INSTANCE_ID"

  # Written first, because everything below can fail. These only ever lived in
  # cloud-init's environment, so a machine whose enrolment failed could not
  # even be told to try again: it no longer knew which deployment it was.
  # Neither value is secret, which is why they can sit here readable.
  mkdir -p /etc/caytu-client
  cat > /etc/caytu-client/deployment.env <<ENVEOF
CAYTU_INSTANCE_ID=$CAYTU_INSTANCE_ID
CAYTU_PLATFORM_URL=${CAYTU_PLATFORM_URL:-}
ENVEOF
  chmod 0644 /etc/caytu-client/deployment.env

  # Fetch the agent. user_data carries this script and nothing else, so the
  # agent it calls has to come from somewhere. S3 with the instance's own role:
  # no credential is written to a customer's machine.
  : "${CAYTU_AGENT_BUCKET:=caytu-cli}"
  : "${CAYTU_AGENT_VERSION:=latest}"
  agent_url="s3://$CAYTU_AGENT_BUCKET/agent/${CAYTU_AGENT_VERSION}.tar.gz"

  log "fetching the agent from $agent_url"
  tmp="$(mktemp -d)"
  if aws s3 cp "$agent_url" "$tmp/agent.tar.gz" >/dev/null 2>&1 \
     && aws s3 cp "${agent_url}.sha256" "$tmp/agent.sha256" >/dev/null 2>&1; then
    # Checked, because this arrives over the network and then runs as root.
    if echo "$(cat "$tmp/agent.sha256")  $tmp/agent.tar.gz" | sha256sum -c - >/dev/null 2>&1; then
      tar -xzf "$tmp/agent.tar.gz" -C "$DEPLOY_DIR"
      chown -R "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_DIR"
      ln -sf "$DEPLOY_DIR/scripts/caytu-client" /usr/local/bin/caytu-client
      log "agent installed from $CAYTU_AGENT_VERSION"
    else
      log "ERROR: the agent download did not match its checksum, refusing to run it"
    fi
  else
    log "ERROR: could not fetch the agent from $agent_url"
    log "  The instance role needs s3:GetObject on that bucket."
  fi
  rm -rf "$tmp"

  # Keep a docker login to our registry alive on the host.
  #
  # The agent runs in a docker:cli container with no aws, and alpine's aws-cli
  # is broken on that image, so the login cannot happen where the pull is
  # started. It happens here instead, and the agent container mounts the result.
  # The token lasts twelve hours, hence the timer rather than a one-off at boot.
  account="$(curl -fsS -m 5 http://169.254.169.254/latest/dynamic/instance-identity/document \
    -H "X-aws-ec2-metadata-token: $(curl -fsS -m 5 -X PUT \
      http://169.254.169.254/latest/api/token \
      -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null)" 2>/dev/null \
    | grep -o '"accountId"[^,]*' | cut -d'"' -f4 || true)"
  region="$(curl -fsS -m 5 http://169.254.169.254/latest/meta-data/placement/region \
    -H "X-aws-ec2-metadata-token: $(curl -fsS -m 5 -X PUT \
      http://169.254.169.254/latest/api/token \
      -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null)" 2>/dev/null || true)"

  if [[ -n "$account" && -n "$region" ]]; then
    registry="$account.dkr.ecr.$region.amazonaws.com"

    cat > /usr/local/bin/caytu-ecr-login <<ECRLOGIN
#!/bin/bash
# Refresh the docker login for our registry. No credential is stored: the
# instance role grants the pull and the token it returns is short lived.
set -e
aws ecr get-login-password --region $region \
  | docker login --username AWS --password-stdin $registry
ECRLOGIN
    chmod +x /usr/local/bin/caytu-ecr-login

    cat > /etc/systemd/system/caytu-ecr-login.service <<'ECRSVC'
[Unit]
Description=Refresh the docker login for the Caytu registry
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
User=DEPLOY_USER_PLACEHOLDER
ExecStart=/usr/local/bin/caytu-ecr-login
ECRSVC
    sed -i "s/DEPLOY_USER_PLACEHOLDER/$DEPLOY_USER/" /etc/systemd/system/caytu-ecr-login.service

    cat > /etc/systemd/system/caytu-ecr-login.timer <<'ECRTIMER'
[Unit]
Description=Keep the Caytu registry login fresh

[Timer]
OnBootSec=1min
OnUnitActiveSec=6h
Persistent=true

[Install]
WantedBy=timers.target
ECRTIMER

    systemctl daemon-reload
    systemctl enable --now caytu-ecr-login.timer >/dev/null 2>&1 || true
    # Now, because provisioning starts within the minute and needs the login.
    if sudo -u "$DEPLOY_USER" /usr/local/bin/caytu-ecr-login >/dev/null 2>&1; then
      log "logged in to $registry"
    else
      log "WARNING: could not log in to $registry; image pulls will be denied"
    fi
  fi

  run_as() { sudo -u "$DEPLOY_USER" env \
    CAYTU_INSTANCE_ID="$CAYTU_INSTANCE_ID" \
    CAYTU_PLATFORM_URL="${CAYTU_PLATFORM_URL:-}" "$@"; }

  if run_as caytu-client --target onprem init >/dev/null 2>&1 \
     && run_as caytu-client --target onprem enroll-self; then
    log "enrolled; starting the provisioner"
    # From here it is the path a customer's own host already follows: the agent
    # claims the deployment it was created for and provisions it.
    run_as caytu-client --target onprem agent up \
      || log "WARNING: the agent did not start; run 'caytu-client -t onprem agent up'"
  else
    # Not fatal: the operator can finish by hand. EC2 can retry the identity
    # flow; a customer's machine has no identity document, so retrying it there
    # is a circle.
    log "WARNING: this machine did not enrol itself."
    if curl -fsS -m 2 -X PUT "http://169.254.169.254/latest/api/token" \
         -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' >/dev/null 2>&1; then
      log "  This looks like EC2, so the identity flow should work. Check the"
      log "  platform is reachable and that AWS_ACCOUNT_ID and"
      log "  AWS_IDENTITY_CERT_PEM are set there, then run:"
      log "    caytu-client -t onprem enroll-self && caytu-client -t onprem agent up"
    else
      log "  This is not an EC2 machine, so it has no identity document to"
      log "  present and enroll-self cannot work here. Create a code in the"
      log "  console under Billings > Instances, then run the two commands it"
      log "  shows you:"
      log "    caytu-client -t onprem enroll <CODE> --platform <your platform url>"
      log "    caytu-client -t onprem instance agent"
    fi
  fi
else
  log "done. remaining steps (from your workstation):"
  log "  caytu-client --target ssh state set ssh_host $(hostname -I | awk '{print $1}')"
  log "  caytu-client --target ssh state set ssh_user $DEPLOY_USER"
  log "  caytu-client --target ssh state set ssh_key_path ~/.ssh/id_ed25519"
  log "  caytu-client --target ssh init"
  log "  # edit compose/.env.ssh"
  log "  caytu-client --target ssh env push"
  log "  caytu-client --target ssh up"
fi
