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
eval "$(sed -n '/^seed_the_store()/,/^}/p'  cluster-agent/agent.sh)"

# Stand in for the cluster and the platform.
KUBECTL_OUT=""; KUBECTL_RC=0; KUBECTL_LOG="$TMP/kubectl.log"
kubectl() { echo "$*" >> "$KUBECTL_LOG"; [ "$KUBECTL_RC" -ne 0 ] && return "$KUBECTL_RC"; printf '%s' "$KUBECTL_OUT"; }
API_OUT=""; API_RC=0; API_LOG="$TMP/api.log"
api() { echo "$1 $2 ${3:-}" >> "$API_LOG"; [ "$API_RC" -ne 0 ] && return "$API_RC"; printf '%s' "$API_OUT"; }

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
echo "a command a cluster cannot do is refused, not ignored"
: > "$API_LOG"; run_command c3 resend-invite '{}'
grep -qE '"status": ?"failed"' "$API_LOG" && ok "reported failed" || bad "not reported as failed"
grep -q "cannot do" "$API_LOG" && ok "says why" || bad "no reason given"

echo
echo "a licence names itself and never carries its token"
: > "$API_LOG"; : > "$KUBECTL_LOG"
run_command c4 install-license '{"licenseId":"lic-9"}'
grep -q "CAYTU_LICENSE_ID=lic-9" "$KUBECTL_LOG" && ok "the id is written" || bad "id not written"
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
out="$(seed_the_store 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "succeeds" || bad "failed: $out"
grep -q -- "--bootstrap-store" "$KUBECTL_LOG" && ok "the store is created first" || bad "never bootstrapped"
grep -q -- "--seal-secrets" "$KUBECTL_LOG" && ok "the secrets are sealed" || bad "never sealed"
# Bootstrap has to come first: sealing refuses without a keyring.
b=$(grep -n -- "--bootstrap-store" "$KUBECTL_LOG" | head -1 | cut -d: -f1)
sl=$(grep -n -- "--seal-secrets" "$KUBECTL_LOG" | head -1 | cut -d: -f1)
[ "$b" -lt "$sl" ] && ok "in that order" || bad "sealed before bootstrapping"

echo
echo "no backend pod yet is not a failure to shout about"
: > "$KUBECTL_LOG"
kubectl() { echo "$*" >> "$KUBECTL_LOG"; :; }
out="$(seed_the_store 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "reports it did not finish" || bad "claimed success with no pod"
grep -q -- "--seal-secrets" "$KUBECTL_LOG" && bad "tried to seal anyway" || ok "did not try to seal"

echo
echo "$P passed, $F failed"
[ "$F" -eq 0 ]
