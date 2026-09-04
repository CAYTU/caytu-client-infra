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
  # A body written as @file is read from that file rather than passed as an
  # argument.
  #
  # Linux caps a single argument at 128KB, and a stack's logs are bigger than
  # that, so curl was never even exec'd: the shell failed with "Argument list
  # too long", the result never reached the platform, and the console sat
  # waiting for an answer nothing had sent. Fetching logs from a cluster
  # therefore worked only while the logs stayed small.
  if [[ "$body" == @* ]]; then
    args+=(--data-binary "$body")
  elif [[ -n "$body" ]]; then
    args+=(-d "$body")
  fi
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

# Add or replace keys in the deployment's secret, leaving the rest alone.
#
# A merge patch, not `create --dry-run | apply`. Apply prunes: the secret was
# created by kustomize with every key in its last-applied annotation, so
# applying a document holding one key deletes the others. That is the database
# password, the JWT secret and the signalling token, gone, on a command whose
# whole job was to write a licence id.
secret_put() {
  local patch; patch="$(jq -nc '$ARGS.positional as $kv
    | reduce range(0; ($kv | length); 2) as $i ({}; .[$kv[$i]] = $kv[$i + 1])
    | {stringData: .}' --args "$@")"
  kubectl -n "$NAMESPACE" patch secret "$SECRET_NAME" --type=merge -p "$patch" \
    >/dev/null 2>&1
}

# What the deployment needs to speak to the platform at all.
#
# The build writes a domain and a billings URL into the cluster's secret and
# stops there, so the backend came up with no deployment id and no credential.
# Everything that depends on those is then silently skipped: the licence it is
# running on is never reported, usage is never metered, and the administrator's
# claim link is never sent, which is why a cluster's invitation email never
# arrived and its licence read "unknown" on the console for ever.
#
# The agent is the only thing in the cluster that holds both: the id it was
# started with, and the credential it earned at enrolment.
publish_platform_credentials() {
  [[ -n "${TOKEN:-}" ]] || return 0

  local current_id current_token
  current_id="$(kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" \
    -o jsonpath='{.data.CAYTU_INSTANCE_ID}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  current_token="$(kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" \
    -o jsonpath='{.data.CAYTU_METERING_TOKEN}' 2>/dev/null | base64 -d 2>/dev/null || true)"

  # Written once and then left alone. These arrive through the environment, so
  # rewriting them on every pass would roll the whole stack every pass.
  [[ "$current_id" == "$INSTANCE_ID" && "$current_token" == "$TOKEN" ]] && return 0

  if ! secret_put CAYTU_INSTANCE_ID "$INSTANCE_ID" CAYTU_METERING_TOKEN "$TOKEN"; then
    log "could not write the platform credential into $SECRET_NAME"
    return 1
  fi

  # The values reach a container through its environment, so a running pod
  # cannot see them. Without this the write is real and has no effect until
  # something else happens to restart the stack.
  kubectl -n "$NAMESPACE" rollout restart deployment >/dev/null 2>&1 || true
  log "wrote the platform credential into $SECRET_NAME and restarted the workloads"
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

# Where this deployment answers, from the ingress itself.
#
# Reported every heartbeat rather than once at build time, so a cluster built
# before anything reported an address gets one, and a balancer that is replaced
# does not leave the console pointing at a name that has moved. The rule's host
# is the answer, not the balancer's own name: that is what the certificate is
# for, so it is the only address a browser will accept.
ingress_url() {
  local host
  host="$(kubectl -n "$NAMESPACE" get ingress \
    -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || true)"
  [[ -n "$host" ]] || return 0
  printf 'https://%s' "$host"
}

# The balancer's own name, which answers before DNS does.
#
# Reported alongside the friendly name for the same reason a machine reports its
# IP as well as its hostname: the CNAME and the certificate arrive later, and
# this is the address that works in the meantime. A browser warns on it, because
# the certificate is for the friendly name.
balancer_url() {
  local host
  host="$(kubectl -n "$NAMESPACE" get ingress \
    -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [[ -n "$host" ]] || return 0
  printf 'https://%s' "$host"
}

# The workloads that are the client itself.
#
# Named rather than discovered. Every deployment in this namespace carries a
# caytu-client image, the agent included, and retagging the agent would kill the
# process running the update halfway through it. mongo, redis and minio are
# StatefulSets and are not ours to move at all.
CLIENT_WORKLOADS=(backend frontend gstreamer-recorder mqtt-streamer signaling-server)

# Which release is actually in the cluster, read off the backend.
#
# The record says what was asked for and only this says what arrived, so an
# update that failed halfway is visible as the two disagreeing rather than as
# silence. The backend is enough: every workload moves together.
running_version() {
  local image
  image="$(kubectl -n "$NAMESPACE" get deploy backend \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  [[ -n "$image" ]] || return 0
  # After the last colon, unless that colon belongs to a registry port.
  local tag="${image##*:}"
  [[ "$tag" == *"/"* ]] || printf '%s' "$tag"
}

heartbeat() {
  # Empty is not "[]": kubectl answering with nothing leaves jq nothing to read,
  # and the whole payload then fails to build, so a cluster the agent could not
  # list reported nothing at all rather than reporting that it is unwell.
  local pods; pods="$(pod_json)"
  [[ -n "$pods" ]] || pods='[]'
  # A cluster where every pod is up is running. Anything else is still
  # provisioning as far as the console is concerned, which is more honest than
  # reporting running for a deployment that serves nothing.
  local bad
  bad="$(printf '%s' "$pods" | jq '[.[] | select(.ready | split("/") | .[0] != .[1])] | length')"

  local payload
  payload="$(jq -nc --argjson p "$pods" --argjson bad "${bad:-0}" \
    --arg u "$(ingress_url)" --arg d "$(balancer_url)" \
    --arg v "$(running_version)" \
    '{clusterPods:$p} + (if $bad == 0 then {status:"running"} else {} end)
                      + (if $u == "" then {} else {publicUrl:$u} end)
                      + (if $d == "" then {} else {directUrl:$d} end)
                      + (if $v == "" then {} else {version:$v} end)')"
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

# A key of this deployment's own, rather than the one every image shares.
#
# The single machine path takes this at provision and writes it to the env file.
# A cluster had nobody doing it, so every one of them sealed with the shard
# baked into the backend image: one key across every customer.
#
# Only before the store exists. The key is what the rows are sealed with, so
# changing it later makes all of them unreadable. Hence ahead of the bootstrap,
# and only on a cluster the build marked as new.
take_a_shard_of_our_own() {
  local secret
  secret="$(kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" -o json 2>/dev/null)" || return 0

  # Set already, and never replaced.
  printf '%s' "$secret" | jq -e '.data.CAYTU_SECRET_STORE_KEY' >/dev/null 2>&1 && return 0
  # No flag means a cluster that predates this and may already hold sealed rows.
  printf '%s' "$secret" | jq -e '.data.CAYTU_STORE_SHARD_WANTED' >/dev/null 2>&1 || return 0

  local shard
  shard="$(api GET "/api/billings/instances/${INSTANCE_ID}/secret-shard" \
    | jq -r '.shard // empty' 2>/dev/null || true)"
  # 204 for a record with no shard, which is not a fault: the baked one works.
  [[ -n "$shard" ]] || return 0

  kubectl -n "$NAMESPACE" patch secret "$SECRET_NAME" --type merge -p "$(
    jq -nc --arg s "$(printf '%s' "$shard" | base64 -w0)" \
      '{data: {CAYTU_SECRET_STORE_KEY: $s}}')" >/dev/null 2>&1 || {
    log "could not store this deployment's shard, so the baked one stays"
    return 0
  }

  # Now, not after sealing. The bootstrap that follows runs in a throwaway pod
  # and picks the new shard up from the secret, while the workloads already
  # running still hold the baked one in their environment. Sealing is what used
  # to restart them, and it returns early when the console holds no secrets,
  # which is every new cluster. The backend was then deriving a different key
  # from the store it had just been given: keyring unreadable, every service
  # failing closed, and nothing on the next pass to put it right.
  kubectl -n "$NAMESPACE" rollout restart deployment >/dev/null 2>&1 || true
  log "took this deployment's own store shard and restarted the workloads"
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

  # Built as JSON first. Passing the command through `jq --args` fails the
  # moment one of its words starts with two dashes, and every command here ends
  # in one: jq read --bootstrap-store as an option to itself.
  local cmd_json
  cmd_json="$(printf '%s\n' "$@" | jq -R . | jq -sc .)"

  local overrides
  overrides="$(jq -nc --arg i "$image" --arg n "$name" \
    --arg org "${ORGANIZATION_ID:-}" --argjson cmd "$cmd_json" '{
    spec: {
      restartPolicy: "Never",
      containers: [{
        name: $n,
        image: $i,
        command: $cmd,
        stdin: true,
        # Closed once the payload is written, so the process sees end of input
        # and exits. Without it the container waits on a pipe nobody will write
        # to again and kubectl gives up on the attach.
        stdinOnce: true,
        env: [{name: "CAYTU_CUSTOMER_ID", value: $org}],
        envFrom: [
          {configMapRef: {name: "caytu-shared"}},
          {secretRef: {name: "caytu-secrets"}}
        ]
      }]
    }
  }')"

  # Waited for, not fired and forgotten. The name is fixed, so a retry that
  # starts before the last pod has finished going away is refused with
  # "object is being deleted", which is what every other attempt hit.
  kubectl -n "$NAMESPACE" delete pod "$name" --ignore-not-found --wait \
    --timeout=60s >/dev/null 2>&1 || true

  # Deliberately not --rm. That makes kubectl hold the attach open until the
  # container is gone, and with a piped payload it times out instead of
  # returning what the command said. The pod is waited for and read here, then
  # removed on the way out.
  if ! kubectl -n "$NAMESPACE" run "$name" -i --quiet --restart=Never \
      --image="$image" --overrides="$overrides" >/dev/null 2>&1; then
    : # It may still have run; the phase below is what decides.
  fi

  kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded \
    "pod/$name" --timeout=120s >/dev/null 2>&1
  local phase
  phase="$(kubectl -n "$NAMESPACE" get pod "$name" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)"

  kubectl -n "$NAMESPACE" logs "$name" 2>&1 || true
  kubectl -n "$NAMESPACE" delete pod "$name" --ignore-not-found --wait=false \
    >/dev/null 2>&1 || true

  [[ "$phase" == "Succeeded" ]]
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
  take_a_shard_of_our_own

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

# What the platform will accept, and nothing a terminal wrote for itself.
#
# The platform caps a stored result at 256KB and truncates anything longer, so
# sending more is bytes nobody reads. The tail is kept rather than the head: the
# end of a log is where the failure is. Escape sequences go because a colour
# code renders as noise in the console's log view.
MAX_RESULT_BYTES=262144

trim_logs() {
  sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g; s/\x1B\][^\x07]*\x07//g' \
    | tail -c "$MAX_RESULT_BYTES"
}

# Why a workload will not come back, in Kubernetes' words.
#
# A rollout timing out says nothing on its own: an image that does not exist, a
# node with no room and a container crashing on boot all look identical from
# here. The reason on the pod is what an operator would go and read, so it
# travels with the failure instead of our guess at it.
workload_trouble() {
  local app=$1 why
  why="$(kubectl -n "$NAMESPACE" get pods -l "app=${app}" -o json 2>/dev/null | jq -r '
    [ .items[] | .status.containerStatuses[]?
      | (.state.waiting // .state.terminated // empty)
      | select(.reason)
      | .reason + (if .message then ": " + (.message | .[0:200]) else "" end) ]
    | first // empty' 2>/dev/null || true)"
  printf '%s' "${why:-no reason reported}"
}

# Move the client workloads onto another release.
#
# Only the tag changes. The repository each Deployment already points at is
# reused, so a cluster pulling from a customer's own registry keeps pulling from
# it, and this cannot quietly repoint a deployment somewhere else.
update_release() {
  local tag=$1
  [[ -n "$tag" ]] || { echo "no version was named"; return 1; }

  # Every image first, then the waiting. One at a time would spend four rollout
  # timeouts against a single deadline, and a stack half on each version is not
  # a state worth pausing in.
  local moved=() name image container
  for name in "${CLIENT_WORKLOADS[@]}"; do
    image="$(kubectl -n "$NAMESPACE" get deploy "$name" \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
    # Not every overlay runs every workload: EKS drops signaling-server because
    # KVS does that job.
    [[ -n "$image" ]] || continue
    container="$(kubectl -n "$NAMESPACE" get deploy "$name" \
      -o jsonpath='{.spec.template.spec.containers[0].name}' 2>/dev/null || true)"
    [[ -n "$container" ]] || continue

    if ! kubectl -n "$NAMESPACE" set image "deploy/${name}" \
        "${container}=${image%:*}:${tag}" >/dev/null 2>&1; then
      echo "${name} would not take ${tag}"
      return 1
    fi
    moved+=("$name")
  done

  [[ ${#moved[@]} -gt 0 ]] || {
    echo "this cluster runs none of the client workloads"
    return 1
  }

  local failed=()
  for name in "${moved[@]}"; do
    kubectl -n "$NAMESPACE" rollout status "deploy/${name}" --timeout=300s \
      >/dev/null 2>&1 || failed+=("${name}: $(workload_trouble "$name")")
  done

  # All of them, not only the ones that failed. A cluster left running two
  # versions of the client is worse than one still on the old release, and
  # nobody asked for that state.
  if [[ ${#failed[@]} -gt 0 ]]; then
    for name in "${moved[@]}"; do
      kubectl -n "$NAMESPACE" rollout undo "deploy/${name}" >/dev/null 2>&1 || true
    done
    local why; why="$(printf '%s; ' "${failed[@]}")"
    echo "${tag} did not come up (${why%; }). Rolled back to the previous version."
    return 1
  fi

  echo "${#moved[@]} workload(s) now running ${tag}"
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
          --tail="$lines" --all-containers --prefix 2>&1 | trim_logs)" \
          || [ -z "$result" ]; then
        # Falls back to the name, for anything not labelled that way.
        result="$(kubectl -n "$NAMESPACE" logs "deployment/${svc}" \
          --tail="$lines" --all-containers 2>&1 | trim_logs)" || {
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
      elif ! secret_put CAYTU_LICENSE_ID "$lic"; then
        status="failed"; error="the licence could not be written to the cluster"
      elif ! kubectl -n "$NAMESPACE" rollout restart deployment/backend >/dev/null 2>&1; then
        status="failed"; error="the licence is configured but the backend did not restart"
      else
        result="licence ${lic} configured; the deployment installs it as it comes back"
      fi
      ;;

    update)
      local tag outcome
      tag="$(printf '%s' "$params" | jq -r '.tag // empty')"
      if ! outcome="$(update_release "$tag")"; then
        status="failed"; error="$outcome"
      else
        result="$outcome"
        # Now rather than at the next heartbeat, so the console shows the new
        # version as soon as it is true.
        heartbeat
      fi
      ;;

    restart)
      # Deployments only. mongo, redis and minio are StatefulSets holding the
      # data, and rolling them to clear a wedged frontend is a much bigger
      # promise than the operator made.
      if kubectl -n "$NAMESPACE" rollout restart deployment >/dev/null 2>&1; then
        result="every workload is restarting; the data is untouched"
      else
        status="failed"; error="the workloads could not be restarted"
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

  # Through files, never arguments, and that goes for jq as well as for curl:
  # the 128KB argument ceiling is the kernel's, so every process in the chain
  # hits it. printf is a shell builtin and execs nothing, which is what makes
  # writing the result out safe when the result is the thing that is too big.
  local work; work="$(mktemp -d)"
  printf '%s' "$result" > "$work/result"

  jq -nc --rawfile r "$work/result" --arg s "$status" --arg e "$error" \
    '{status:$s} + (if $r == "" then {} else {result:$r} end)
              + (if $e == "" then {} else {error:$e} end)' > "$work/payload"

  if api PATCH "/api/billings/instances/${INSTANCE_ID}/commands/${id}" \
      "@$work/payload" >/dev/null; then
    log "command ${type} -> ${status}${error:+: $error}"
  else
    # The work happened and the console will never hear about it. Saying it
    # finished here is how a command sits at "waiting" until it expires.
    log "command ${type} ran, but the result could not be delivered"
  fi
  rm -rf "$work"
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

# Before anything else it might do: a backend with no credential cannot report
# its licence, cannot meter, and cannot mail the administrator their link.
publish_platform_credentials || true

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
