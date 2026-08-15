# Secrets

> **Which stack this describes:** the deployment stack in this repository's
> `compose/` directory, the one a customer runs. The application repository has
> a `docs/secret-store.md` covering its own compose files, which carry the same
> filenames with different behaviour. This is the document to follow when
> provisioning a real host.

**Nothing sensitive is checked into git.** Secrets reach a deployment two ways:

- **One `.env` file** per deployment under `compose/` (gitignored) — infrastructure and application configuration, rsynced to the host mode 600 by `env push`. Covered immediately below.
- **The encrypted store in MongoDB** — the backend's own secret vault, loaded with `caytu-client secrets seed`. See [Secret store in MongoDB](#secret-store-in-mongodb).

## The env file

There is **one** env file per deployment, `compose/.env.<target>` (e.g.
`.env.local`, `.env.aws-single`). Copy it from
[`compose/.env.example`](../compose/.env.example) with `caytu-client -t <target> init`.

It does two jobs at once:

| Job | Mechanism |
|---|---|
| `${VAR}` substitution in the compose files | `docker compose --env-file compose/.env.<target>` |
| The environment inside every container | each service declares `env_file: ./.env` |

The compose files hardcode `./.env` (matching production), while the repo keeps
one file per target so you can have several configured side by side. The CLI
bridges the two by symlinking `compose/.env` → `.env.<target>` immediately before
invoking compose, locally and on the remote. A symlink rather than a copy, so
editing `.env.<target>` can never leave a stale `.env` behind.

**Every variable reaches every container.** With a single shared file the
frontend also sees `MINIO_ROOT_PASSWORD` and `TURN_SECRET`, not just the services
that need them. This matches production. Anything that must not be that widely
visible belongs in the encrypted Mongo store instead.

## Rotation

To rotate a secret:

1. Update the value in `compose/.env.<target>` on your workstation.
2. `caytu-client -t <target> env push`
3. `caytu-client -t <target> restart <affected-service>` (or `deploy` if you also want a fresh image).

Container env vars are set at start time — a live container will not pick up a changed env file.

## Secret store in MongoDB

Separate from the `.env` files above, the backend reads its sensitive
configuration from an encrypted store in the `caytu_secrets` MongoDB database:

| Collection | Contents |
|---|---|
| `keyring` | one document (`_id: 'current'`) — which key encrypted the values, and with what algorithm |
| `vault` | one document per secret, `_id` = the secret's name (e.g. `JWT_SECRET`) |
| `runtime_meta`, `worker_meta`, `media_meta` | per-service anti-rollback ratchets — see [Ratchet state](#ratchet-state) |

**AWS IoT device certificates live here too.** The device cert, private key and
CA used for IoT Core and KVS are vault entries, not files. Nothing is
bind-mounted into the containers, and there are no `AWS_IOT_CERT_PATH`-style
variables to set.

**Encryption happens outside this repo.** A separate `encrypt-secrets.sh` (in
the caytu-client app repo) turns a plaintext `.env.secrets` file into an
encrypted `vault.json`. This infra repo never sees, stores, or transports
plaintext — it only takes the already-encrypted output and loads it into Mongo.

The committed template that lists every secret name the stack looks for is
[`compose/vault/.env.secrets.example`](../compose/vault/.env.secrets.example) —
copy it to `compose/vault/.env.secrets`, fill in real values, then encrypt.

### Seeding

```bash
# 1) Author the plaintext (once per deployment, then edit as secrets rotate)
cp compose/vault/.env.secrets.example compose/vault/.env.secrets
$EDITOR compose/vault/.env.secrets

# 2) Encrypt (SECRET_STORE_KEY_B64 must equal CAYTU_SECRET_STORE_KEY in
#    compose/.env.<target> — that's how the backend derives the same key)
SECRET_STORE_KEY_B64=<shard> CUSTOMER_ID=<id> \
  /path/to/caytu-client/encrypt-secrets.sh \
    --input compose/vault/.env.secrets \
    --out   compose/vault/vault.json

# 3) Seed the encrypted blob
caytu-client -t <target> secrets seed --in compose/vault/vault.json

# or piped in one shot, with -y since stdin is taken by the payload:
SECRET_STORE_KEY_B64=<shard> CUSTOMER_ID=<id> \
  /path/to/caytu-client/encrypt-secrets.sh --input compose/vault/.env.secrets \
  | caytu-client -t aws-single secrets seed -y
```

Works on every target. Compose targets (`local`, `onprem`, `ssh`, `aws-single`,
`gcp-single`) go through `docker compose exec mongodb`; cluster targets
(`aws-cluster`, `gcp-cluster`, `self-managed-k8s`) go through `kubectl exec` into
the mongodb pod. Set `MONGO_CONTAINER=<name>` to override the lookup entirely.

Before writing anything it validates the JSON shape locally, then prints the
target, database, and **key names only — never values** — and asks you to
confirm. `-y` skips the prompt.

Seeding is idempotent: each secret is upserted by name, so re-running updates in
place rather than duplicating. A stale monolithic `_id:'current'` document in
`vault` (the older format) is removed, since it would otherwise shadow the
per-key rows.

`SECRETS_DB` overrides the database name, which is useful for testing against a
throwaway database:

```bash
SECRETS_DB=caytu_secrets_test caytu-client -t local secrets seed --in fixture.json -y
```

### Ratchet state

If the input JSON carries a `state` key, those groups seed the per-service
anti-rollback ratchets — one collection per service (`runtime_meta`,
`worker_meta`, `media_meta`), none of which reads the others:

```json
"state": [
  {"collection": "runtime_meta", "rows": [{"_id": "hwm", "v": 1730000000}]}
]
```

These are written with **`$setOnInsert`, never `$set`** — they are created if
absent and otherwise left exactly as they are. That's deliberate and
security-relevant: the values only ever move forward, and a re-seed carries an
*install-time* high-water mark that is by definition older than whatever the
running service has since recorded. Using `$set` would let the seeding tool itself
roll the ratchet backwards, turning the deployment tooling into the attack.

So a re-seed reports something like `runtime_meta: 0 created, 1 left untouched`.
That is the correct outcome, not a failure. The `state` key is optional — input
without it seeds normally.

This replaced an earlier filesystem-based scheme that bound to `/etc/machine-id`
and kept state on a named volume. That broke on every `--force-recreate` and was
erased by `down --volumes`; nothing is bind-mounted for licensing any more.

### Why it pipes instead of `--eval`

The payload is piped to `mongosh` on **stdin**, never passed as a command-line
argument. Anything in argv is visible in `ps aux` to every other user on the host
for as long as the command runs — so an `--eval "$json"` call would expose the
entire encrypted blob. Piping also means the file never lands on the remote
filesystem and leaves nothing behind when the command exits.

The `vault*.json` and `*.vault.json` patterns are gitignored. Encrypted or not, a
secret blob does not belong in git.

## What about Vault?

The optional `vault` service (behind `--profile vault`) runs in **dev mode** with an in-memory backend and a root token of `root`. That's fine for local development where the signaling server or backend want a token endpoint to poke against, but do not use it as a production secret store.

If you need a hardened secret store in production, either:

- Point services at your existing Vault / AWS Secrets Manager / GCP Secret Manager instance and pass the credentials via `.env.<target>`, **or**
- Provision a real Vault (out of scope for this repo) and point services at it via `VAULT_ADDR` + `VAULT_TOKEN`.

## What lives on the remote host

After `env push`:

```
/opt/caytu-client/compose/
  .env.<target>            # mode 600, owner deploy user — the only env file
  .env -> .env.<target>    # symlink the CLI maintains; what compose reads
  nginx/
  monitoring/
  backup/
  docker-compose*.yml
```

The deploy user is the one who ran `bootstrap.sh` (typically `ubuntu` on AWS/GCP Ubuntu images). Rotate the SSH key that reaches this user as part of your regular access review.

## In CI

For CI/CD, put secrets in GitHub Actions Secrets (or equivalent) and render `.env.<target>` at pipeline time before `caytu-client env push`. Do not check the file in, even encrypted.
