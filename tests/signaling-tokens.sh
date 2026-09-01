#!/usr/bin/env bash
# The signaling server refuses every peer unless the tokens file it reads holds
# the same token the peers send. Nobody should have to keep those in step.
set -uo pipefail
SRC="$(dirname "$(dirname "$(readlink -f "$0")")")"
PASS=0; FAIL=0
check() { [[ "$2" == "$3" ]] && { echo "  PASS  $1"; PASS=$((PASS+1)); } || { echo "  FAIL  $1: expected $2, got $3"; FAIL=$((FAIL+1)); }; }

source "$SRC/scripts/lib/common.sh" >/dev/null 2>&1
eval "$(sed -n '/^preflight_signaling_tokens()/,/^}/p' "$SRC/scripts/caytu-client")"

d="$(mktemp -d)"
COMPOSE_DIR="$d"
tokens="$d/secrets/signaling-tokens.json"

echo
echo "writing the signaling tokens file"

# A comment on the same line is how our own templates document a choice.
env="$d/.env.onprem"
printf 'SIGNALING_AUTH_DRIVER=static   # static | jwt | vault\nSIGNALING_AUTH_TOKEN=abc123\n' > "$env"
check "an inline comment is not part of the value" "static" "$(env_get "$env" SIGNALING_AUTH_DRIVER)"

preflight_signaling_tokens "$env" >/dev/null 2>&1
check "the file is written" 1 "$([[ -f "$tokens" ]] && echo 1 || echo 0)"
check "keyed by the token the peers send" 1 "$(grep -c '"abc123"' "$tokens")"
check "no placeholder survives" 0 "$(grep -c 'REPLACE_WITH' "$tokens")"
check "valid json" 1 "$(jq -e . "$tokens" >/dev/null 2>&1 && echo 1 || echo 0)"
# uid 1001 inside the container has to open a file owned by whoever ran `up`.
check "readable by the container user" 644 "$(stat -c '%a' "$tokens")"

# The token changing is the normal case: the platform pushes settings.
env_upsert "$env" SIGNALING_AUTH_TOKEN "def456"
preflight_signaling_tokens "$env" >/dev/null 2>&1
check "follows the token when it changes" 1 "$(grep -c '"def456"' "$tokens")"
check "the old token stops working" 0 "$(grep -c '"abc123"' "$tokens")"

# Someone who added a second peer by hand should not lose it on the next `up`.
jq '. + {"another":{"id":"x","username":"x"}}' "$tokens" > "$tokens.new" && mv "$tokens.new" "$tokens"
preflight_signaling_tokens "$env" >/dev/null 2>&1
check "hand-added entries are kept" 1 "$(grep -c '"another"' "$tokens")"

# No token at all is the state a fresh install starts in.
rm -f "$tokens"
printf 'SIGNALING_AUTH_DRIVER=static\nSIGNALING_AUTH_TOKEN=\n' > "$env"
preflight_signaling_tokens "$env" >/dev/null 2>&1
generated="$(env_get "$env" SIGNALING_AUTH_TOKEN)"
check "a missing token is generated" 64 "${#generated}"
check "and written to the file" 1 "$(grep -c "\"$generated\"" "$tokens")"

# Another driver never reads the file, but a missing bind-mount source becomes
# a directory and the container dies on that instead.
rm -f "$tokens"
printf 'SIGNALING_AUTH_DRIVER=vault\nSIGNALING_AUTH_TOKEN=\n' > "$env"
preflight_signaling_tokens "$env" >/dev/null 2>&1
check "other drivers still get a file" 1 "$([[ -f "$tokens" ]] && echo 1 || echo 0)"

echo
echo "what the shipped envs select"
# .env.example is the one every install starts from; the per-target files are
# gitignored copies of it.
check ".env.example uses a driver the peers speak" "static" \
  "$(env_get "$SRC/compose/.env.example" SIGNALING_AUTH_DRIVER)"
# The image refuses allow-all when NODE_ENV=production, which compose sets.
check ".env.local is the only allow-all" "allow-all" "$(env_get "$SRC/compose/.env.local" SIGNALING_AUTH_DRIVER)"

# createAuth() knows four drivers; anything else leaves the pod with no adapter.
k8s="$SRC/kubernetes/base/signaling-server.yaml"
check "k8s picks a real driver" 1 "$(grep -c 'value: "static"' "$k8s")"
check "k8s writes its tokens file" 1 "$(grep -c 'write-tokens' "$k8s")"

rm -rf "$d"
echo
printf '  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
