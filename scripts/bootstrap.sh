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
