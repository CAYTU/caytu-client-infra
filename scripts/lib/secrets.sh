# shellcheck shell=bash
# Seeds the backend's encrypted secret store into MongoDB.
#
# The store lives in the `caytu_secrets` database as:
#   keyring  — one document (_id:'current') describing which key encrypted the
#              values and with what algorithm
#   vault    — one document per secret, _id = the secret's name
#   state    — per-service anti-rollback ratchets (runtime_meta, worker_meta,
#              media_meta). Seeded once and never overwritten; see the
#              $setOnInsert note in secrets_seed().
#
# Input is the already-encrypted JSON blob produced by encrypt-secrets.sh, which
# lives outside this repo. We never see, transport, or store plaintext.
#
# The payload is piped to mongosh on stdin rather than passed via --eval, so it
# never appears in argv (visible to any user via `ps`) and never lands on the
# remote filesystem.

SECRETS_DB="${SECRETS_DB:-caytu_secrets}"

# Run a mongosh script (read from stdin) against SECRETS_DB on the current
# target. Reuses compose() for the docker targets — it already knows how to
# reach both a local daemon and a remote host over SSH, and ssh forwards stdin
# to the remote command unchanged.
_secrets_mongosh() {
  local db=${1:-$SECRETS_DB}

  # Escape hatch for setups the target dispatch doesn't cover (a Mongo running
  # outside compose, a differently-named container).
  if [[ -n "${MONGO_CONTAINER:-}" ]]; then
    docker exec -i "$MONGO_CONTAINER" mongosh --quiet "$db"
    return
  fi

  case "$TARGET" in
    local|onprem|ssh|aws-single|gcp-single)
      # -T disables TTY allocation; with a TTY the piped script is mangled.
      compose exec -T mongodb mongosh --quiet "$db" --file /dev/stdin ;;
    aws-cluster|gcp-cluster|self-managed-k8s)
      require_cmd kubectl
      local ns pod
      ns="$(_k8s_ns)"
      pod="$(kubectl -n "$ns" get pod -l app=mongodb \
               -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
      [[ -n "$pod" ]] || die "no mongodb pod found in namespace $ns"
      # -i, never -it: a TTY would corrupt stdin.
      kubectl -n "$ns" exec -i "$pod" -- mongosh --quiet "$db" --file /dev/stdin ;;
    *)
      die "unsupported target for secrets: $TARGET" ;;
  esac
}

# Ask for confirmation on the terminal rather than stdin. The payload may have
# arrived on stdin (`cat vault.json | … secrets seed`), leaving nothing for a
# plain `read` — which would silently abort the seed and still exit 0.
_secrets_confirm() {
  local prompt=$1 reply=""
  # `[[ -r /dev/tty ]]` only checks permissions — the node exists but opening it
  # fails with ENXIO when there's no controlling terminal (CI, setsid, cron).
  # Actually opening it is the only reliable test.
  { : < /dev/tty; } 2>/dev/null \
    || die "no terminal available to confirm — re-run with -y to seed non-interactively"

  read -r -p "$prompt [y/N] " reply < /dev/tty || true
  [[ "$reply" =~ ^([yY]|yes|YES)$ ]]
}

secrets_seed() {
  require_cmd jq

  local in="" assume_yes=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --in)      in="$2"; shift 2 ;;
      --in=*)    in="${1#*=}"; shift ;;
      -y|--yes)  assume_yes=1; shift ;;
      *) die "unknown argument: $1 (usage: caytu-client secrets seed [--in FILE] [-y])" ;;
    esac
  done

  local json
  if [[ -n "$in" ]]; then
    [[ -f "$in" ]] || die "input file not found: $in"
    json="$(cat "$in")"
  else
    [[ ! -t 0 ]] || die "no input — pass --in FILE or pipe JSON on stdin"
    json="$(cat)"
  fi
  [[ -n "$json" ]] || die "empty input — expected the JSON from encrypt-secrets.sh"

  # Validate locally so a malformed file fails before we touch the database
  # rather than half-applying.
  jq -e . >/dev/null 2>&1 <<<"$json" || die "input is not valid JSON"
  jq -e '.keyring | type == "object"' >/dev/null 2>&1 <<<"$json" \
    || die "input has no 'keyring' object"
  jq -e '.rows | type == "array"' >/dev/null 2>&1 <<<"$json" \
    || die "input has no 'rows' array"
  jq -e 'all(.rows[]; has("name") and (.name | type == "string") and (.name | length > 0))' \
    >/dev/null 2>&1 <<<"$json" || die "every row must have a non-empty string 'name'"

  # `state` is optional — absence must not fail. When present it must be well
  # formed, since each group names a collection we write to by hand.
  if jq -e 'has("state")' >/dev/null 2>&1 <<<"$json"; then
    jq -e '.state | type == "array"' >/dev/null 2>&1 <<<"$json" \
      || die "'state' must be an array"
    jq -e 'all(.state[];
             (.collection | type == "string") and (.collection | length > 0)
             and (.rows | type == "array")
             and all(.rows[]; has("_id") and (._id | tostring | length > 0)))' \
      >/dev/null 2>&1 <<<"$json" \
      || die "every state group needs a non-empty 'collection' and rows with a non-empty '_id'"
  fi

  local count names
  count="$(jq -r '.rows | length' <<<"$json")"
  names="$(jq -r '[.rows[].name] | join(", ")' <<<"$json")"

  # Names and counts only — never values.
  info "target   : $TARGET"
  info "database : $SECRETS_DB"
  info "keyring  : 1 document"
  info "vault    : $count key(s) — $names"

  local state_summary
  state_summary="$(jq -r '[(.state // [])[] | "\(.collection) (\(.rows | length))"] | join(", ")' <<<"$json")"
  [[ -n "$state_summary" ]] && info "state    : $state_summary (created only if absent)"

  if [[ "$assume_yes" != "1" ]]; then
    _secrets_confirm "Overwrite these secrets in $SECRETS_DB on '$TARGET'?" || {
      info "aborted — nothing written"
      return 1
    }
  fi

  # Upsert the keyring, drop the legacy monolithic vault blob (it would shadow
  # the per-key rows), then write one document per secret keyed by its name so
  # re-seeding updates in place instead of duplicating.
  #
  # The `state` groups are the exception: $setOnInsert, NOT $set. Those are the
  # per-service anti-rollback ratchets (runtime_meta / worker_meta / media_meta —
  # one per service, none reading the others) and their values only ever move
  # forward. A re-seed carries an install-time high-water mark that is by
  # definition older than whatever is already stored, so $set here would let the
  # seeding tool itself roll the ratchet back. Existing rows must be left exactly
  # as they are.
  _secrets_mongosh <<EOF
const d = $json;
db.keyring.updateOne({_id:'current'}, {\$set: d.keyring}, {upsert:true});
db.vault.deleteOne({_id:'current'});
let n = 0;
for (const r of (d.rows || [])) {
  const {name, ...rest} = r;
  db.vault.updateOne({_id:name}, {\$set: {...rest, updated_at: new Date()}}, {upsert:true});
  n++;
}
for (const grp of (d.state || [])) {
  let created = 0, kept = 0;
  for (const r of (grp.rows || [])) {
    const res = db.getCollection(grp.collection).updateOne(
      {_id: r._id},
      {\$setOnInsert: {v: r.v, updated_at: new Date()}},
      {upsert: true});
    if (res.upsertedCount) { created++; } else { kept++; }
  }
  print('[secrets] ' + grp.collection + ': ' + created + ' created, ' + kept + ' left untouched (already present)');
}
print('[secrets] upserted keyring + ' + n + ' vault row(s) into $SECRETS_DB');
EOF

  ok "seeded $count secret(s) into $SECRETS_DB on '$TARGET'"
}
