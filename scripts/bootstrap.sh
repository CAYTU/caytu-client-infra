#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — one-shot host bootstrap for Ubuntu/Debian
#
#   # A machine of your own, all the way to a running deployment. The code
#   # comes from the console, under Billings > Instances.
#   curl -fsSL https://raw.githubusercontent.com/CAYTU/caytu-client-infra/main/scripts/bootstrap.sh \
#     | sudo CAYTU_CODE=<CODE> CAYTU_PLATFORM=https://your.platform bash
#
#   # Prepare the machine only, and enrol it yourself later:
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

  # Ours, not this machine's. The account read above is where the machine runs,
  # which is our account for hosting we run and the customer's for a deployment
  # in theirs. Logging in there authenticated against repositories that exist
  # and are empty, while compose pulled from ours with no credentials at all,
  # so every pull failed and the rest reported a cancelled context.
  #
  # The region is ours for the same reason: ECR is regional and the images are
  # in one region, whatever region the machine sits in.
  image_account="${CAYTU_IMAGE_ACCOUNT:-688544396352}"
  image_region="${CAYTU_IMAGE_REGION:-us-east-1}"

  # Installed on every host, not just EC2. The script below tries the machine's
  # own AWS identity first and falls back to a password the platform mints, and
  # on-prem hardware has no identity at all: gating this on IMDS answering left
  # exactly those hosts with no login and every pull failing.
  registry="$image_account.dkr.ecr.$image_region.amazonaws.com"
  region="$image_region"

  # A fixed, user-independent path — matches the compose default. Writing to
  # $DEPLOY_USER's $HOME used to bite non-ubuntu hosts (root-only boxes, NVIDIA
  # Spark) whose compose mount then pointed at a directory nobody had touched.
  docker_cfg=/var/lib/caytu-client/.docker
  mkdir -p "$docker_cfg"
  chmod 700 "$docker_cfg"

  cat > /usr/local/bin/caytu-ecr-login <<ECRLOGIN
#!/bin/bash
# Refresh the docker login for our registry, tried in two ways.
#
#   1. The host's own AWS identity: an instance role on a hosted machine,
#      or a machine-configured profile. When it works, no round trip.
#   2. A short-lived password minted by the platform, using the enrolment
#      token as authentication. This is the path that works on a customer's
#      own hardware, where the host holds no AWS credential.
#
# The systemd timer that runs this used to call \`aws ecr get-login-password\`
# unconditionally. Any host without a working AWS credential (customer boxes
# provisioned with baked keys that were later rotated, on-prem hosts, etc.)
# then had its docker login expire twelve hours after the last successful
# refresh, and every pull started failing with "no basic auth credentials".
set -e

REGISTRY="$registry"
REGION="$region"
DEPLOY_DIR="$DEPLOY_DIR"
# Scopes every docker CLI call below to a fixed directory the agent container
# mounts read-only. Not the caller's \$HOME/.docker: that varies with sudo/su
# and never matches the compose mount on a non-ubuntu host.
export DOCKER_CONFIG="$docker_cfg"

log() { printf '[caytu-ecr-login] %s\n' "\$*"; }

# Path 1: the host's own AWS identity.
if command -v aws >/dev/null 2>&1; then
  if aws ecr get-login-password --region "\$REGION" 2>/dev/null \\
       | docker login --username AWS --password-stdin "\$REGISTRY" >/dev/null 2>&1; then
    log "logged in to \$REGISTRY (aws identity)"
    exit 0
  fi
fi

# Path 2: platform-minted credential, per configured target.
#
# A host can carry more than one target (\`.env.<target>\` per deployment it
# manages). Each target has its own platform URL and metering token, and a
# token minted for one platform is a 401 at another — so URL and token have
# to be read together from the SAME env file. Any target's success is enough
# for docker: it's the same shared Caytu ECR every deployment pulls from.
attempted=0
for env_file in "\$DEPLOY_DIR/compose"/.env.*; do
  [ -f "\$env_file" ] || continue
  case "\$env_file" in *.example) continue ;; esac

  platform_url=""
  for key in PLATFORM_HOST_URL CAYTU_PLATFORM_URL CAYTU_BILLINGS_URL; do
    v="\$(sed -n "s|^\${key}=\\(.*\\)\$|\\1|p" "\$env_file" | head -1)"
    if [ -n "\$v" ]; then platform_url="\${v%/}"; break; fi
  done
  token="\$(sed -n 's/^CAYTU_METERING_TOKEN=\\(.*\\)\$/\\1/p' "\$env_file" | head -1)"

  if [ -z "\$platform_url" ] || [ -z "\$token" ]; then continue; fi
  attempted=\$((attempted + 1))

  body="\$(curl -fsS -m 20 \\
    "\$platform_url/api/billings/instances/registry-credentials" \\
    -H "Authorization: Bearer \$token" 2>/dev/null || true)"
  [ -z "\$body" ] && { log "no response from \$platform_url"; continue; }

  user="\$(printf '%s' "\$body" | jq -r '.username // empty')"
  pass="\$(printf '%s' "\$body" | jq -r '.password // empty')"
  host="\$(printf '%s' "\$body" | jq -r '.registry // empty')"
  target_registry="\${host:-\$REGISTRY}"

  if [ -z "\$user" ] || [ -z "\$pass" ]; then
    log "\$platform_url returned no username/password"
    continue
  fi

  if printf '%s' "\$pass" | docker login --username "\$user" --password-stdin "\$target_registry" >/dev/null 2>&1; then
    log "logged in to \$target_registry (platform-issued via \$(basename "\$env_file"))"
    exit 0
  fi
  log "docker login rejected the credential from \$platform_url"
done

if [ "\$attempted" -eq 0 ]; then
  log "no aws identity and no enrolment token — nothing to try"
else
  log "tried \$attempted target(s), none succeeded"
fi
exit 1
ECRLOGIN
  chmod +x /usr/local/bin/caytu-ecr-login

  cat > /etc/systemd/system/caytu-ecr-login.service <<'ECRSVC'
[Unit]
Description=Refresh the docker login for the Caytu registry
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
# Runs as root: the script writes to /var/lib/caytu-client/.docker (root-owned)
# and talks to /var/run/docker.sock. No $HOME hoisting to worry about.
ExecStart=/usr/local/bin/caytu-ecr-login
ECRSVC

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
  if /usr/local/bin/caytu-ecr-login >/dev/null 2>&1; then
    log "logged in to $registry"
  else
    log "WARNING: could not log in to $registry; image pulls will be denied"
  fi

  run_as() { sudo -u "$DEPLOY_USER" env \
    CAYTU_INSTANCE_ID="$CAYTU_INSTANCE_ID" \
    CAYTU_PLATFORM_URL="${CAYTU_PLATFORM_URL:-}" "$@"; }

  # The agent container mounts this to get the registry login, and its default
  # is /home/ubuntu, which only exists on a cloud image. On any other host the
  # mount resolves to a directory docker invents, so the pull it starts has no
  # credentials however well the host itself is logged in.
  mkdir -p "/home/$DEPLOY_USER/.docker"
  chown "$DEPLOY_USER:$DEPLOY_USER" "/home/$DEPLOY_USER/.docker"
  env_line="CAYTU_DOCKER_CONFIG=/home/$DEPLOY_USER/.docker"

  if run_as caytu-client --target onprem init >/dev/null 2>&1 \
     && run_as caytu-client --target onprem enroll-self; then
    log "enrolled; starting the provisioner"
    # From here it is the path a customer's own host already follows: the agent
    # claims the deployment it was created for and provisions it.
    onprem_env="$DEPLOY_DIR/compose/.env.onprem"
    if [[ -f "$onprem_env" ]] && ! grep -q '^CAYTU_DOCKER_CONFIG=' "$onprem_env"; then
      printf '%s\n' "$env_line" >> "$onprem_env"
    fi

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
  # A machine that is not one of ours: somebody's own server, on their own
  # network.
  #
  # The agent above comes from S3 using the instance's AWS role. This machine
  # has no AWS identity and never will, so it takes the same files from the
  # repository this script was itself downloaded from. Same two directories the
  # published tarball carries, and nothing else: a host has no use for the
  # terraform or the docs.
  install_agent_from_source() {
    local ref="${CAYTU_AGENT_REF:-main}"
    local url="https://codeload.github.com/CAYTU/caytu-client-infra/tar.gz/${ref}"

    log "installing the client from ${ref}"
    local tmp; tmp="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN

    if ! curl -fsSL "$url" -o "$tmp/src.tar.gz"; then
      log "ERROR: could not download the client from GitHub."
      log "  The repository has to be public for this to work. If it is not yet,"
      log "  that is the reason, and nothing here can work around it."
      return 1
    fi

    # --strip-components drops the caytu-client-infra-<ref>/ wrapper GitHub adds.
    tar -xzf "$tmp/src.tar.gz" -C "$DEPLOY_DIR" --strip-components=1 \
      --wildcards '*/scripts' '*/compose' 2>/dev/null || {
      log "ERROR: the download did not contain scripts and compose"
      return 1
    }

    chown -R "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_DIR"
    ln -sf "$DEPLOY_DIR/scripts/caytu-client" /usr/local/bin/caytu-client
    log "installed caytu-client"
  }

  if install_agent_from_source; then
    if [[ -n "${CAYTU_CODE:-}" ]]; then
      # One command from the console, ending with a deployment that is running.
      # Splitting this across three commands is what left a machine prepared and
      # empty, with instructions naming a program that was never installed.
      : "${CAYTU_PLATFORM:?CAYTU_CODE was given, so CAYTU_PLATFORM is required}"

      log "enrolling with the code you were given"
      sudo -u "$DEPLOY_USER" caytu-client -t onprem enroll "$CAYTU_CODE" \
        --platform "$CAYTU_PLATFORM"

      # `agent up`, which is a container, not `instance agent`, which is a loop
      # in this shell. The loop dies with the terminal that started it, and a
      # deployment whose agent is gone answers nothing the console asks: no
      # logs, no settings, no purge. This path is the one most hosts take.
      log "starting the agent, which brings the deployment up"
      sudo -u "$DEPLOY_USER" caytu-client -t onprem agent up \
        || log "WARNING: the agent did not start; run 'caytu-client -t onprem agent up'"
      log "the deployment comes up in the background; follow it with 'caytu-client -t onprem agent logs'"
      log "done"
    else
      log "done. Create a code in the console under Billings > Instances, then:"
      log "  caytu-client -t onprem enroll <CODE> --platform <your platform url>"
      log "  caytu-client -t onprem agent up"
      log ""
      log "Or re-run this with the code and it will do both:"
      log "  ... | sudo CAYTU_CODE=<CODE> CAYTU_PLATFORM=<url> bash"
    fi
  fi
fi
