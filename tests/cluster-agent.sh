#!/usr/bin/env bash
# The cluster's agent: what it reports, and what it does when told.
set -uo pipefail
cd "$(dirname "$0")/.."

P=0; F=0
ok()  { echo "  PASS  $1"; P=$((P+1)); }
bad() { echo "  FAIL  $1"; F=$((F+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# The agent's own functions, without its loop.
NAMESPACE=caytu-client
SECRET_NAME=caytu-secrets
PLATFORM_URL=http://platform.test
INSTANCE_ID=abc123
TOKEN=tok
log() { :; }
eval "$(sed -n '/^pod_json()/,/^}/p'      cluster-agent/agent.sh)"
eval "$(sed -n '/^apply_settings()/,/^}/p' cluster-agent/agent.sh)"
eval "$(sed -n '/^run_command()/,/^}/p'    cluster-agent/agent.sh)"
eval "$(sed -n '/^secret_put()/,/^}/p'     cluster-agent/agent.sh)"
eval "$(sed -n '/^publish_platform_credentials()/,/^}/p' cluster-agent/agent.sh)"
eval "$(sed -n '/^trim_logs()/,/^}/p'      cluster-agent/agent.sh)"
eval "$(sed -n '/^MAX_RESULT_BYTES=/p'     cluster-agent/agent.sh)"
eval "$(sed -n '/^seed_the_store()/,/^}/p'  cluster-agent/agent.sh)"
eval "$(sed -n '/^take_a_shard_of_our_own()/,/^}/p' cluster-agent/agent.sh)"
eval "$(sed -n '/^ingress_url()/,/^}/p'     cluster-agent/agent.sh)"
eval "$(sed -n '/^balancer_url()/,/^}/p'    cluster-agent/agent.sh)"
eval "$(sed -n '/^heartbeat()/,/^}/p'       cluster-agent/agent.sh)"
eval "$(sed -n '/^CLIENT_WORKLOADS=/p'      cluster-agent/agent.sh)"
eval "$(sed -n '/^running_version()/,/^}/p'  cluster-agent/agent.sh)"
eval "$(sed -n '/^workload_trouble()/,/^}/p' cluster-agent/agent.sh)"
eval "$(sed -n '/^update_release()/,/^}/p'   cluster-agent/agent.sh)"
# Stands in for the throwaway pod. Records the command it was asked to run.
RUN_LOG="$TMP/run.log"; RUN_RC=0
run_with_backend_image() { local n=$1; shift; echo "$n: $*" >> "$RUN_LOG"; cat >/dev/null; return "$RUN_RC"; }

# Stand in for the cluster and the platform.
KUBECTL_OUT=""; KUBECTL_RC=0; KUBECTL_LOG="$TMP/kubectl.log"
kubectl() { echo "$*" >> "$KUBECTL_LOG"; [ "$KUBECTL_RC" -ne 0 ] && return "$KUBECTL_RC"; printf '%s' "$KUBECTL_OUT"; }
API_OUT=""; API_RC=0; API_LOG="$TMP/api.log"
# A body written as @file is read from the file, exactly as the real one does.
api() {
  local body="${3:-}"
  [[ "$body" == @* ]] && body="$(cat "${body#@}")"
  echo "$1 $2 $body" >> "$API_LOG"
  [ "$API_RC" -ne 0 ] && return "$API_RC"
  printf '%s' "$API_OUT"
}

echo "what is running is reported in the cluster's own words"
KUBECTL_OUT='{"items":[
 {"metadata":{"name":"backend-1"},"spec":{"containers":[{"n":1}]},
  "status":{"phase":"Running","containerStatuses":[{"ready":true,"restartCount":0}]}},
 {"metadata":{"name":"frontend-1"},"spec":{"containers":[{"n":1}]},
  "status":{"phase":"Pending","containerStatuses":[{"ready":false,"restartCount":0,
    "state":{"waiting":{"reason":"ImagePullBackOff"}}}]}}]}'
out="$(pod_json)"
[ "$(printf '%s' "$out" | jq -r '.[0].ready')" = "1/1" ] && ok "ready count" || bad "ready was $(printf '%s' "$out" | jq -r '.[0].ready')"
# The reason beats the phase, or a bad image looks like a slow start.
[ "$(printf '%s' "$out" | jq -r '.[1].phase')" = "ImagePullBackOff" ] \
  && ok "the waiting reason wins over the phase" || bad "phase was $(printf '%s' "$out" | jq -r '.[1].phase')"

echo
echo "settings are written and the workloads rolled"
: > "$KUBECTL_LOG"
API_OUT='{"settings":{"OPENAI_API_KEY":"sk-abc","TURN_SECRET":"t"}}'; API_RC=0
KUBECTL_OUT=""; KUBECTL_RC=0
out="$(apply_settings)"
[ "$out" = "2" ] && ok "reports how many" || bad "reported '$out'"
grep -q "apply -f -" "$KUBECTL_LOG" && ok "the secret is applied" || bad "no secret apply"
# Patching the secret alone changes nothing a running pod can see.
grep -q "rollout restart deployment" "$KUBECTL_LOG" && ok "the workloads are rolled" || bad "no rollout"

echo
echo "nothing to do is not a failure"
API_OUT='{"settings":{}}'; API_RC=0
out="$(apply_settings)"; rc=$?
[ "$rc" -eq 0 ] && ok "succeeds" || bad "failed"
[[ "$out" == *"no settings"* ]] && ok "says so" || bad "said '$out'"

echo
echo "a platform that does not answer does not touch the cluster"
: > "$KUBECTL_LOG"
API_RC=7
out="$(apply_settings)"; rc=$?
[ "$rc" -ne 0 ] && ok "fails" || bad "reported success"
[ ! -s "$KUBECTL_LOG" ] && ok "the cluster was left alone" || bad "changed the cluster anyway"

echo
echo "teardown keeps the data, purge does not"
API_RC=0; API_OUT=""; KUBECTL_RC=0
: > "$KUBECTL_LOG"; run_command c1 teardown '{}'
grep -q -- "--replicas=0" "$KUBECTL_LOG" && ok "teardown scales to zero" || bad "teardown did something else"
grep -q "delete namespace" "$KUBECTL_LOG" && bad "teardown deleted the namespace" || ok "teardown leaves the volumes"

: > "$KUBECTL_LOG"; run_command c2 purge '{}'
grep -q "delete namespace" "$KUBECTL_LOG" && ok "purge removes everything" || bad "purge did not"

echo
echo "a restart rolls the workloads and leaves the data alone"
: > "$KUBECTL_LOG"; KUBECTL_RC=0
run_command c12 restart '{}'
grep -q "rollout restart deployment" "$KUBECTL_LOG" && ok "the workloads roll" || bad "nothing rolled"
grep -qE "rollout restart statefulset|delete|--replicas" "$KUBECTL_LOG" \
  && bad "touched the data tier" || ok "mongo, redis and minio are left alone"

echo
echo "a command a cluster cannot do is refused, not ignored"
: > "$API_LOG"; run_command c3 resend-invite '{}'
grep -qE '"status": ?"failed"' "$API_LOG" && ok "reported failed" || bad "not reported as failed"
grep -q "cannot do" "$API_LOG" && ok "says why" || bad "no reason given"

echo
echo "a licence names itself and never carries its token"
: > "$API_LOG"; : > "$KUBECTL_LOG"
run_command c4 install-license '{"licenseId":"lic-9"}'
grep -q '"CAYTU_LICENSE_ID":"lic-9"' "$KUBECTL_LOG" && ok "the id is written" || bad "id not written"
grep -q "rollout restart deployment/backend" "$KUBECTL_LOG" && ok "the backend is rolled" || bad "backend not rolled"

echo
echo "the store is seeded, and minio is told the same thing twice"
: > "$KUBECTL_LOG"
API_RC=0
API_OUT='{"settings":{},"secrets":{"SMS_ENCRYPTION_KEY":"k"},"files":{}}'
# The build put MinIO's password in the Kubernetes secret; the backend reads it
# from the store, so both have to agree.
kubectl() {
  echo "$*" >> "$KUBECTL_LOG"
  case "$*" in
    *"jsonpath={.items[0].metadata.name}"*) echo "backend-abc" ;;
    *MINIO_ROOT_USER*)     printf 'caytu' | base64 ;;
    *MINIO_ROOT_PASSWORD*) printf 's3cret' | base64 ;;
    *) : ;;
  esac
}
SEALED=""
# Already known, as it is for any agent that enrolled with this version.
ORGANIZATION_ID=org123
TOKEN=tok
out="$(seed_the_store 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "succeeds" || bad "failed: $out"
grep -q -- "--bootstrap-store" "$RUN_LOG" && ok "the store is created first" || bad "never bootstrapped"
grep -q -- "--seal-secrets" "$RUN_LOG" && ok "the secrets are sealed" || bad "never sealed"
# Bootstrap has to come first: sealing refuses without a keyring.
b=$(grep -n -- "--bootstrap-store" "$RUN_LOG" | head -1 | cut -d: -f1)
sl=$(grep -n -- "--seal-secrets" "$RUN_LOG" | head -1 | cut -d: -f1)
[ "${b:-0}" -lt "${sl:-0}" ] && ok "in that order" || bad "sealed before bootstrapping"
# The whole point of the throwaway pod: the backend cannot start until the
# store exists, so seeding must never depend on the backend running.
grep -q "exec" "$KUBECTL_LOG" && bad "still execs into the backend" || ok "does not need a running backend"

echo
echo "an agent with no organization id asks the platform for it"
: > "$RUN_LOG"
ORGANIZATION_ID=""
API_OUT='{"instances":[{"id":"abc123","organizationId":"org-from-platform"}]}'
kubectl() { echo "$*" >> "$KUBECTL_LOG"; :; }
INSTANCE_ID=abc123
seed_the_store >/dev/null 2>&1
# Asserted on the value, not the log line: log() is silenced in here.
[ "$ORGANIZATION_ID" = "org-from-platform" ] && ok "recovers it" || bad "got '$ORGANIZATION_ID'"
ORGANIZATION_ID=org123
API_OUT='{"settings":{},"secrets":{"SMS_ENCRYPTION_KEY":"k"},"files":{}}'

echo
echo "a long log still reaches the platform"
# Linux refuses to exec an argument over 128KB, so a result passed on the
# command line was never sent at all and the console waited for ever.
: > "$API_LOG"; API_RC=0
KUBECTL_OUT="$(head -c 400000 /dev/zero | tr '\0' 'x')"
kubectl() { printf '%s' "$KUBECTL_OUT"; }
run_command c9 logs '{"service":"backend","lines":200}'
[ -s "$API_LOG" ] && ok "the result was delivered" || bad "nothing was sent"
grep -qE '"status": ?"done"' "$API_LOG" && ok "reported done" || bad "not reported done"
# Capped to what the platform stores, keeping the end: that is where a failure is.
size="$(wc -c < "$API_LOG")"
[ "$size" -lt 300000 ] && ok "capped to what the platform accepts" || bad "sent $size bytes"

echo
echo "a result that cannot be delivered is not called finished"
: > "$API_LOG"; API_RC=7
KUBECTL_OUT="some logs"
# The agent's own logger, which the harness otherwise silences.
log() { echo "$*"; }
out="$(run_command c10 logs '{"service":"backend"}' 2>&1)"
log() { :; }
[[ "$out" == *"could not be delivered"* ]] \
  && ok "says the console never heard" || bad "said '$out'"
API_RC=0
KUBECTL_OUT=""

echo
echo "the heartbeat says where the deployment answers"
: > "$API_LOG"
KUBECTL_OUT=""
kubectl() {
  echo "$*" >> "$KUBECTL_LOG"
  case "$*" in
    *"spec.rules[0].host"*) echo "promed.caytu.link" ;;
    *"status.loadBalancer.ingress[0].hostname"*) echo "k8s-caytu-abc.us-east-1.elb.amazonaws.com" ;;
    *"get pods"*) echo '{"items":[{"metadata":{"name":"backend-1"},"spec":{"containers":[{"n":1}]},"status":{"phase":"Running","containerStatuses":[{"ready":true,"restartCount":0}]}}]}' ;;
    *) : ;;
  esac
}
API_RC=0; API_OUT=""
heartbeat
# The rule's host, not the balancer's own name: the certificate is for that one.
grep -q '"publicUrl":"https://promed.caytu.link"' "$API_LOG" \
  && ok "the address is reported" || bad "no address in $(cat "$API_LOG")"
# The balancer's own name too: it answers before the CNAME does, which is the
# window somebody watching a build is in.
grep -q '"directUrl":"https://k8s-caytu-abc.us-east-1.elb.amazonaws.com"' "$API_LOG" \
  && ok "the balancer's own name is reported" || bad "no balancer name reported"

echo
echo "a cluster with no ingress reports no address, rather than a broken one"
kubectl() { echo "$*" >> "$KUBECTL_LOG"; :; }
: > "$API_LOG"
heartbeat
grep -q "publicUrl" "$API_LOG" && bad "invented an address" || ok "says nothing"
echo "an update moves the client onto another release"
# A cluster as it actually is: four workloads, no signaling-server, images in
# our registry.
ROLLOUT_RC=0
kubectl() {
  echo "$*" >> "$KUBECTL_LOG"
  local args="$*" name
  name="${args#*get deploy }"; name="${name%% *}"
  case "$args" in
    *"containers[0].image"*)
      [ "$name" = "signaling-server" ] && return 1
      echo "reg.test/caytu-client-${name}:v1.0.0" ;;
    *"containers[0].name"*) echo "$name" ;;
    *"rollout status"*) return "$ROLLOUT_RC" ;;
    *"get pods"*) echo '{"items":[{"status":{"containerStatuses":[{"state":{"waiting":{"reason":"ImagePullBackOff","message":"manifest unknown"}}}]}}]}' ;;
    *) : ;;
  esac
}
: > "$KUBECTL_LOG"
out="$(update_release v1.2.0)"; rc=$?
[ "$rc" -eq 0 ] && ok "succeeds" || bad "failed: $out"
grep -q "set image deploy/backend backend=reg.test/caytu-client-backend:v1.2.0" "$KUBECTL_LOG" \
  && ok "only the tag changes" || bad "the image was rewritten"
# The overlay drops signaling-server, and a workload that is not there is not a
# failure.
grep -q "set image deploy/signaling-server" "$KUBECTL_LOG" \
  && bad "moved a workload that is not deployed" || ok "skips what is not deployed"
# Retagging the agent would kill the process running the update.
grep -q "set image deploy/cluster-agent" "$KUBECTL_LOG" \
  && bad "retagged the agent itself" || ok "leaves the agent alone"
# The databases are not ours to move.
grep -qE "set image (deploy|statefulset)/(mongodb|redis|minio)" "$KUBECTL_LOG" \
  && bad "touched a stateful workload" || ok "leaves mongo, redis and minio alone"

echo
echo "an update that does not come up is rolled back, with the cluster's reason"
: > "$KUBECTL_LOG"
ROLLOUT_RC=1
out="$(update_release v1.2.0)"; rc=$?
[ "$rc" -ne 0 ] && ok "reports failure" || bad "claimed success"
[[ "$out" == *"ImagePullBackOff"* ]] && ok "carries the real reason" || bad "said '$out'"
grep -q "rollout undo deploy/backend" "$KUBECTL_LOG" \
  && ok "rolls back" || bad "left the cluster half moved"
ROLLOUT_RC=0

echo
echo "the version the cluster is actually on is read off the backend"
[ "$(running_version)" = "v1.0.0" ] && ok "reports it" || bad "reported '$(running_version)'"
# An image with no tag has nothing to report, and the last path segment is not a
# version.
kubectl() { echo "reg.test/caytu-client-backend"; }
[ -z "$(running_version)" ] && ok "says nothing when there is no tag" || bad "invented a version"

echo
echo "an update with no version named is refused"
out="$(update_release "")"; rc=$?
[ "$rc" -ne 0 ] && ok "fails" || bad "accepted it"

echo
echo "the workloads are given the platform credential"
# Without these the backend reports no licence, meters nothing, and never mails
# the administrator their claim link.
: > "$KUBECTL_LOG"
INSTANCE_ID=abc123; TOKEN=tok-123
kubectl() { echo "$*" >> "$KUBECTL_LOG"; :; }
publish_platform_credentials
grep -q "patch secret caytu-secrets --type=merge" "$KUBECTL_LOG" \
  && ok "written as a merge, not a replace" || bad "did not patch the secret"
grep -q "CAYTU_INSTANCE_ID.*abc123" "$KUBECTL_LOG" && ok "the deployment id" || bad "no instance id"
grep -q "CAYTU_METERING_TOKEN.*tok-123" "$KUBECTL_LOG" && ok "and the credential" || bad "no token"
# They reach a container through its environment, so a running pod cannot see
# them until it restarts.
grep -q "rollout restart deployment" "$KUBECTL_LOG" && ok "and the stack is rolled" || bad "no restart"

echo
echo "and only once"
: > "$KUBECTL_LOG"
kubectl() {
  echo "$*" >> "$KUBECTL_LOG"
  case "$*" in
    *CAYTU_INSTANCE_ID*) printf 'abc123' | base64 ;;
    *CAYTU_METERING_TOKEN*) printf 'tok-123' | base64 ;;
  esac
}
publish_platform_credentials
grep -q "patch secret" "$KUBECTL_LOG" && bad "wrote them again" || ok "leaves a stack it already told"
grep -q "rollout restart" "$KUBECTL_LOG" && bad "restarted the stack for nothing" || ok "and does not restart it"

echo
echo "a licence is written without taking the other secrets with it"
: > "$KUBECTL_LOG"
kubectl() { echo "$*" >> "$KUBECTL_LOG"; :; }
run_command c11 install-license '{"licenseId":"lic-9"}'
grep -q "patch secret caytu-secrets --type=merge" "$KUBECTL_LOG" \
  && ok "merged in" || bad "still replaces the whole secret"
grep -q "create secret generic" "$KUBECTL_LOG" \
  && bad "apply would prune every other key" || ok "nothing is pruned"

echo
echo "a bootstrap that fails does not go on to seal"
: > "$RUN_LOG"; RUN_RC=1
out="$(seed_the_store 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "reports it did not finish" || bad "claimed success"
grep -q -- "--seal-secrets" "$RUN_LOG" && bad "sealed without a keyring" || ok "did not try to seal"
RUN_RC=0

echo
echo "a shard of this deployment's own"

b64() { printf '%s' "$1" | base64 -w0; }

# Earlier cases left a kubectl that answers nothing, and this reads the secret
# before it decides.
KUBECTL_RC=0; API_RC=0
kubectl() { echo "$*" >> "$KUBECTL_LOG"; printf '%s' "$KUBECTL_OUT"; }

# Already keyed. Taking another would make every sealed row unreadable.
: > "$API_LOG"; : > "$KUBECTL_LOG"
KUBECTL_OUT="$(jq -nc --arg k "$(b64 old-shard)" --arg w "$(b64 1)" \
  '{data: {CAYTU_SECRET_STORE_KEY: $k, CAYTU_STORE_SHARD_WANTED: $w}}')"
API_OUT='{"shard":"new-shard"}'
take_a_shard_of_our_own
grep -q "secret-shard" "$API_LOG" && bad "asked for a shard it already has" || ok "an existing key is left alone"
grep -q "patch secret" "$KUBECTL_LOG" && bad "patched over the existing key" || ok "and nothing is patched"

# No flag: a cluster built before this, which may already hold sealed rows.
: > "$API_LOG"; : > "$KUBECTL_LOG"
KUBECTL_OUT='{"data":{"JWT_SECRET":"eA=="}}'
take_a_shard_of_our_own
grep -q "secret-shard" "$API_LOG" && bad "re-keyed an older cluster" || ok "an older cluster keeps the baked shard"

# A new cluster, which is the whole point.
: > "$API_LOG"; : > "$KUBECTL_LOG"
KUBECTL_OUT="$(jq -nc --arg w "$(b64 1)" '{data: {CAYTU_STORE_SHARD_WANTED: $w}}')"
API_OUT='{"shard":"new-shard"}'
take_a_shard_of_our_own
grep -q "instances/abc123/secret-shard" "$API_LOG" && ok "a new cluster asks for its own" || bad "never asked"
if grep -q "patch secret" "$KUBECTL_LOG" && grep -q "$(b64 new-shard)" "$KUBECTL_LOG"; then
  ok "and the shard is written into the secret"
  # The pods already running hold the baked shard in their environment, and
  # sealing, which used to be what restarted them, does not run on a cluster
  # whose console holds no secrets.
  grep -q "rollout restart deployment" "$KUBECTL_LOG" \
    && ok "and the workloads are restarted onto it" \
    || bad "left the workloads on the baked shard"
else
  bad "the shard was not written"
fi

# 204: a record with no shard. The baked one still works, so not a fault.
: > "$KUBECTL_LOG"
API_OUT=''
take_a_shard_of_our_own
grep -q "patch secret" "$KUBECTL_LOG" && bad "wrote an empty shard" || ok "no shard on the record writes nothing"

echo
echo "$P passed, $F failed"
[ "$F" -eq 0 ]
