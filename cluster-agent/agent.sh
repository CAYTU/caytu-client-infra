#!/usr/bin/env bash
# The part of a cluster deployment that can act on it.
#
# A single machine runs scripts/caytu-client as a loop on the box: it enrols,
# reports, and answers the console's commands. A cluster has no such box, so
# until this existed a cluster could be built and then nothing could be done
# with it. It reported nothing, answered nothing, and the console could not tell
# a healthy cluster from a dead one.
#
# This is the same loop against a different substrate. Where the machine agent
# runs `docker compose`, this talks to the Kubernetes API: settings become a
# Secret and a rollout, logs come from pods, teardown scales to zero.
#
# It deliberately does not share code with the machine agent. That script is
# built around one host with one env file and one compose project, and the
# overlap here is the platform's HTTP contract rather than any of the doing.
set -uo pipefail

PLATFORM_URL="${CAYTU_PLATFORM_URL:?the platform address is required}"
INSTANCE_ID="${CAYTU_INSTANCE_ID:?the deployment id is required}"
NAMESPACE="${CAYTU_NAMESPACE:-caytu-client}"
SECRET_NAME="${CAYTU_SECRET_NAME:-caytu-secrets}"
CREDENTIAL_SECRET="${CAYTU_CREDENTIAL_SECRET:-caytu-agent-credential}"
POLL_SECONDS="${CAYTU_POLL_SECONDS:-15}"
HEARTBEAT_SECONDS="${CAYTU_HEARTBEAT_SECONDS:-60}"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

api() {
  local method=$1 path=$2 body=${3:-}
  local args=(-sS -m 30 -X "$method" "${PLATFORM_URL}${path}"
              -H "Authorization: Bearer ${TOKEN}"
              -H 'Content-Type: application/json')
  [[ -n "$body" ]] && args+=(-d "$body")
  curl "${args[@]}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Enrolment
#
# A node in this cluster is an EC2 instance, so it can prove what it is the same
# way a single machine does: with its signed instance identity document. That
# means one enrolment mechanism rather than a second one invented for clusters.
#
# The credential is kept in a Secret so a restarted pod reuses it. Enrolling
# again would mint a second credential every time the pod moved, and the
# platform refuses that anyway once a machine is already enrolled.
# ---------------------------------------------------------------------------

imds() {
  local path=$1 token
  token="$(curl -sS -m 5 -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null)" || return 1
  curl -sS -m 5 "http://169.254.169.254/latest/${path}" \
    -H "X-aws-ec2-metadata-token: ${token}" 2>/dev/null
}

stored_token() {
  kubectl -n "$NAMESPACE" get secret "$CREDENTIAL_SECRET" \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null
}

store_token() {
  kubectl -n "$NAMESPACE" create secret generic "$CREDENTIAL_SECRET" \
    --from-literal=token="$1" --from-literal=organizationId="${2:-}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

stored_org() {
  kubectl -n "$NAMESPACE" get secret "$CREDENTIAL_SECRET" \
    -o jsonpath='{.data.organizationId}' 2>/dev/null | base64 -d 2>/dev/null
}

enrol() {
  local doc sig body
  doc="$(imds dynamic/instance-identity/document)" || return 1
  # rsa2048, not `signature`. IMDS offers three forms of the same proof and the
  # platform verifies this one; `signature` is the SHA-1 form and is refused as
  # "not signed by AWS", which reads like a broken document rather than the
  # wrong format. The machine agent has always used rsa2048.
  sig="$(imds dynamic/instance-identity/rsa2048)" || return 1
  [[ -n "$doc" && -n "$sig" ]] || return 1

  body="$(jq -n --arg d "$doc" --arg s "$sig" --arg i "$INSTANCE_ID" \
    '{document:$d, signature:$s, instanceId:$i}')"

  local out
  out="$(curl -sS -m 30 -X POST "${PLATFORM_URL}/api/auth/enroll/instance" \
    -H 'Content-Type: application/json' -d "$body" 2>/dev/null)" || return 1

  local token org
  token="$(printf '%s' "$out" | jq -r '.token // empty')"
  # The store's key is derived partly from this, so bootstrapping needs it and
  # only the enrolment reply carries it.
  org="$(printf '%s' "$out" | jq -r '.organizationId // empty')"
  [[ -n "$token" ]] || {
    log "enrolment refused: $(printf '%s' "$out" | jq -r '.errors[0].message // "unknown"')"
    return 1
  }

  store_token "$token" "$org"
  TOKEN="$token"
  ORGANIZATION_ID="$org"
  log "enrolled, credential stored in $CREDENTIAL_SECRET"
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

# What is actually running. The waiting reason beats the phase: the API's phase
# is only ever Pending, Running, Succeeded, Failed or Unknown, so an image that
# will not pull looks exactly like a pod that is merely starting.
pod_json() {
  kubectl -n "$NAMESPACE" get pods -o json 2>/dev/null | jq -c '
    [.items[] | . as $p | {
      name: $p.metadata.name,
      phase: ([$p.status.containerStatuses[]?.state.waiting.reason // empty] | first
              // $p.status.phase // "Unknown"),
      ready: ("\([$p.status.containerStatuses[]? | select(.ready)] | length)/\($p.spec.containers | length)"),
      restarts: ([$p.status.containerStatuses[]?.restartCount] | add // 0)
    }]' || echo '[]'
}

heartbeat() {
  local pods; pods="$(pod_json)"
  # A cluster where every pod is up is running. Anything else is still
  # provisioning as far as the console is concerned, which is more honest than
  # reporting running for a deployment that serves nothing.
  local bad
  bad="$(printf '%s' "$pods" | jq '[.[] | select(.ready | split("/") | .[0] != .[1])] | length')"

  local payload
  payload="$(jq -nc --argjson p "$pods" --argjson bad "${bad:-0}" \
    '{clusterPods:$p} + (if $bad == 0 then {status:"running"} else {} end)')"
  api PATCH "/api/billings/instances/${INSTANCE_ID}/state" "$payload" >/dev/null
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

# Everything the deployment runs with, as the console holds it. Written to the
# Secret the workloads already mount, then the Deployments are rolled so the new
# values are actually in the containers. Patching the Secret alone changes
# nothing a running pod can see.
apply_settings() {
  local body
  body="$(api GET "/api/billings/instances/${INSTANCE_ID}/settings/resolved")" || {
    echo "the platform did not answer, so nothing was changed"; return 1
  }

  local count
  count="$(printf '%s' "$body" | jq -r '.settings | length' 2>/dev/null || echo 0)"
  if [[ -z "$count" || "$count" == "0" || "$count" == "null" ]]; then
    echo "the console holds no settings for this deployment, so nothing changed"
    return 0
  fi

  # Merged into what is already there rather than replacing it: the Secret also
  # holds values provisioning wrote, and replacing it wholesale would drop them.
  local args=()
  local key value
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    value="$(printf '%s' "$body" | jq -r --arg k "$key" '.settings[$k]')"
    args+=(--from-literal="${key}=${value}")
  done < <(printf '%s' "$body" | jq -r '.settings | keys[]')

  local existing merged
  existing="$(kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" -o json 2>/dev/null)"
  if [[ -n "$existing" ]]; then
    while IFS= read -r key; do
      [[ -n "$key" ]] || continue
      printf '%s' "$body" | jq -e --arg k "$key" '.settings | has($k)' >/dev/null && continue
      value="$(printf '%s' "$existing" | jq -r --arg k "$key" '.data[$k]' | base64 -d)"
      args+=(--from-literal="${key}=${value}")
    done < <(printf '%s' "$existing" | jq -r '.data // {} | keys[]')
  fi

  kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
    "${args[@]}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null || {
    echo "the settings could not be written to the cluster"; return 1
  }

  kubectl -n "$NAMESPACE" rollout restart deployment >/dev/null 2>&1 || {
    echo "the settings were written but the workloads did not restart"; return 1
  }

  echo "$count"
}

# Make sure this deployment has an encrypted store, and that it holds what the
# console knows.
#
# The machine agent does this at provision. A cluster had nobody doing it, so
# the store stayed empty and the backend fell back to its defaults: it looked
# for MinIO credentials, found none, and tried "minioadmin" against a MinIO that
# had a real password. The error it printed was about an access key, which is
# three steps from the cause.
#
# Two calls, and the order matters. Bootstrap creates the keyring the ratchet is
# written against and refuses to touch a store that already has one. Sealing
# needs that keyring to exist and refuses without it.
# Run one command with the backend's image, on its own.
#
# Not `kubectl exec` into the backend pod. That was a deadlock: the backend
# crash-loops when the store is empty, so the container is not running, so there
# is nothing to exec into, so the store stays empty. The image is what carries
# the shard, not the running pod, so a throwaway pod does the job.
#
# Same config as the backend, or the key it derives would not match the one the
# backend derives, and it would seal rows nothing could read.
run_with_backend_image() {
  local name=$1; shift
  local image
  image="$(kubectl -n "$NAMESPACE" get deploy backend \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  [[ -n "$image" ]] || return 1

  local overrides
  overrides="$(jq -nc --arg i "$image" --arg n "$name" \
    --arg org "${ORGANIZATION_ID:-}" --args '{
    spec: {
      restartPolicy: "Never",
      containers: [{
        name: $n,
        image: $i,
        command: $ARGS.positional,
        stdin: true,
        env: [{name: "CAYTU_CUSTOMER_ID", value: $org}],
        envFrom: [
          {configMapRef: {name: "caytu-shared"}},
          {secretRef: {name: "caytu-secrets"}}
        ]
      }]
    }
  }' "$@")"

  # Removed first. --rm does not clean up after a failed run, and the name is
  # fixed, so a second attempt would collide with the remains of the first.
  kubectl -n "$NAMESPACE" delete pod "$name" --ignore-not-found --wait=false \
    >/dev/null 2>&1 || true

  kubectl -n "$NAMESPACE" run "$name" --rm -i --quiet --restart=Never \
    --image="$image" --overrides="$overrides" 2>&1
}

# Make sure this deployment has an encrypted store, and that it holds what the
# console knows.
#
# The machine agent does this at provision. A cluster had nobody doing it, so
# the store stayed empty and the backend fell back to its defaults: it looked
# for MinIO credentials, found none, and tried "minioadmin" against a MinIO that
# had a real password. The error it printed was about an access key, which is
# three steps from the cause.
#
# Two calls, and the order matters. Bootstrap creates the keyring the ratchet is
# written against and refuses to touch a store that already has one. Sealing
# needs that keyring to exist and refuses without it.
seed_the_store() {
  local out

  # An agent that enrolled before this stored the organization id has none, and
  # re-enrolling is refused once a machine is already enrolled. Asked for
  # instead, over the credential it already holds.
  if [[ -z "${ORGANIZATION_ID:-}" ]]; then
    ORGANIZATION_ID="$(api GET "/api/billings/instances" \
      | jq -r --arg id "$INSTANCE_ID" \
        '.instances[]? | select(.id == $id) | .organizationId // empty' 2>/dev/null || true)"
    if [[ -n "$ORGANIZATION_ID" ]]; then
      store_token "$TOKEN" "$ORGANIZATION_ID"
      log "recovered the organization id from the platform"
    else
      log "no organization id, so the store cannot be bootstrapped"
      return 1
    fi
  fi
  if ! out="$(printf '' | run_with_backend_image caytu-store-bootstrap \
      node loader.js --bootstrap-store)"; then
    log "could not bootstrap the secret store: $(printf '%s' "$out" | tail -1)"
    return 1
  fi

  local body
  body="$(api GET "/api/billings/instances/${INSTANCE_ID}/settings/resolved")" || {
    log "the platform did not answer, so the store keeps what it has"
    return 1
  }

  # What the console holds, plus the credentials this deployment generated for
  # itself at build time.
  #
  # MinIO is the one that bites. Its password is made when the cluster is built
  # and put in the Kubernetes secret so MinIO can start with it, but the backend
  # reads that credential from the store and never from the environment. So the
  # two have to be told the same thing, and only this can do it.
  local minio_user minio_password
  minio_user="$(kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" \
    -o jsonpath='{.data.MINIO_ROOT_USER}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  minio_password="$(kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" \
    -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)"

  local payload
  payload="$(printf '%s' "$body" | jq -c \
    --arg u "$minio_user" --arg p "$minio_password" '
    {env: (.secrets // {}), files: (.files // {})}
    | if $u != "" and (.env.MINIO_ACCESS_KEY // "") == ""
      then .env.MINIO_ACCESS_KEY = $u else . end
    | if $p != "" and (.env.MINIO_SECRET_KEY // "") == ""
      then .env.MINIO_SECRET_KEY = $p else . end')"

  local count
  count="$(printf '%s' "$payload" | jq '(.env | length) + (.files | length)')"
  if [[ "${count:-0}" -eq 0 ]]; then
    log "the console holds no secrets for this deployment"
    return 0
  fi

  if out="$(printf '%s' "$payload" | run_with_backend_image caytu-store-seal \
      node loader.js --seal-secrets)"; then
    log "sealed ${count} secret(s) into the store"
    kubectl -n "$NAMESPACE" rollout restart deployment >/dev/null 2>&1 || true
  else
    log "could not seal the secrets into the store: $(printf '%s' "$out" | tail -1)"
    return 1
  fi
}

run_command() {
  local id=$1 type=$2 params=$3
  local status="done" error="" result=""

  case "$type" in
    apply-settings)
      local outcome
      if ! outcome="$(apply_settings)"; then
        status="failed"; error="$outcome"
      elif [[ "$outcome" =~ ^[0-9]+$ ]]; then
        result="$outcome setting(s) written and the workloads restarted"
      else
        result="$outcome"
      fi
      ;;

    logs)
      local svc lines
      svc="$(printf '%s' "$params" | jq -r '.service // "backend"')"
      lines="$(printf '%s' "$params" | jq -r '.lines // 200')"
      # By label, not by workload kind. `deployment/x` fails on a StatefulSet,
      # and mongo, redis and minio are all StatefulSets, so the one pod worth
      # reading when a deployment will not start was the one this could not
      # reach.
      if ! result="$(kubectl -n "$NAMESPACE" logs -l "app=${svc}" \
          --tail="$lines" --all-containers --prefix 2>&1)" || [ -z "$result" ]; then
        # Falls back to the name, for anything not labelled that way.
        result="$(kubectl -n "$NAMESPACE" logs "deployment/${svc}" \
          --tail="$lines" --all-containers 2>&1)" || {
          status="failed"; error="could not read the logs for ${svc}"
        }
      fi
      ;;

    install-license)
      # The credential never travels through here, exactly as on a machine. The
      # cluster is told which licence to run and fetches its own token.
      local lic
      lic="$(printf '%s' "$params" | jq -r '.licenseId // empty')"
      if [[ -z "$lic" ]]; then
        status="failed"; error="no licence was named"
      elif ! kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
          --from-literal="CAYTU_LICENSE_ID=${lic}" --dry-run=client -o yaml \
          | kubectl apply -f - >/dev/null 2>&1; then
        status="failed"; error="the licence could not be written to the cluster"
      elif ! kubectl -n "$NAMESPACE" rollout restart deployment/backend >/dev/null 2>&1; then
        status="failed"; error="the licence is configured but the backend did not restart"
      else
        result="licence ${lic} configured; the deployment installs it as it comes back"
      fi
      ;;

    teardown)
      # Workloads, not data. Scaled to zero rather than deleted, because the
      # volumes stay and a restore is a scale back up. Ending a billing
      # arrangement is not consent to destroy a customer's database.
      if kubectl -n "$NAMESPACE" scale deployment --all --replicas=0 >/dev/null 2>&1; then
        result="every workload scaled to zero; the data volumes are untouched"
      else
        status="failed"; error="the workloads could not be scaled down"
      fi
      ;;

    purge)
      # The deliberate opposite of teardown, and it takes the volumes with it.
      # The cluster itself is Terraform's to remove; this is everything running
      # inside it.
      if kubectl delete namespace "$NAMESPACE" --wait=false >/dev/null 2>&1; then
        result="the deployment and its volumes are being removed"
      else
        status="failed"; error="the namespace could not be removed"
      fi
      ;;

    *)
      status="failed"; error="a cluster cannot do '${type}'"
      ;;
  esac

  local payload
  payload="$(jq -nc --arg s "$status" --arg r "$result" --arg e "$error" \
    '{status:$s} + (if $r == "" then {} else {result:$r} end)
              + (if $e == "" then {} else {error:$e} end)')"
  api PATCH "/api/billings/instances/${INSTANCE_ID}/commands/${id}" "$payload" >/dev/null
  log "command ${type} -> ${status}${error:+: $error}"
}

poll_commands() {
  local body
  body="$(api GET "/api/billings/instances/${INSTANCE_ID}/commands?claim=true")" || return 0
  local count
  count="$(printf '%s' "$body" | jq -r '.commands | length' 2>/dev/null || echo 0)"
  [[ "$count" =~ ^[0-9]+$ ]] && [[ "$count" -gt 0 ]] || return 0

  local i id type params
  for ((i = 0; i < count; i++)); do
    id="$(printf '%s' "$body" | jq -r ".commands[$i].id")"
    type="$(printf '%s' "$body" | jq -r ".commands[$i].type")"
    params="$(printf '%s' "$body" | jq -c ".commands[$i].params // {}")"
    run_command "$id" "$type" "$params"
  done
}

# ---------------------------------------------------------------------------

TOKEN="$(stored_token)"
ORGANIZATION_ID="$(stored_org)"
if [[ -z "$TOKEN" ]]; then
  log "no credential yet, enrolling"
  until enrol; do
    log "enrolment failed, trying again in 30s"
    sleep 30
  done
fi

log "agent up for ${INSTANCE_ID} in ${NAMESPACE}"

# Once, at startup. A deployment with an empty store cannot serve anything, so
# this is not something to wait for a console command to trigger.
# Tried now, and again on every pass until it takes.
#
# The first attempt lands seconds after the cluster is built, when mongo is
# still holding its election, and the seeding needs a primary to write to. One
# shot at startup meant a deployment could sit crash looping forever over a
# race it would have won a minute later.
STORE_SEEDED=0
seed_the_store && STORE_SEEDED=1 \
  || log "the store is not seeded yet; trying again shortly"
last_beat=0
while true; do
  now="$(date +%s)"
  if (( now - last_beat >= HEARTBEAT_SECONDS )); then
    heartbeat
    last_beat="$now"
  fi
  if (( STORE_SEEDED == 0 )) && (( now - last_beat < 2 )); then
    seed_the_store && STORE_SEEDED=1
  fi

  poll_commands
  sleep "$POLL_SECONDS"
done
