# Secrets

**Nothing sensitive is checked into git.** All secrets live in `.env.*` files under `compose/`, which are gitignored. The CLI's `env push` rsyncs them (mode 600) to the remote deploy directory.

## Files

| File | Purpose | Loaded by |
|---|---|---|
| `.env.local`, `.env.ssh`, `.env.<target>` | Deployment-wide config: image registry, MinIO creds, TURN secret, monitoring passwords, backup keys | `docker compose --env-file …` |
| `.env.backend` | Backend-specific: JWT_SECRET, LLM API keys, SMTP, Clerk, IoT | `backend` container `env_file` |
| `.env.frontend` | Frontend build/runtime: Clerk keys, public URLs | `frontend` container `env_file` |
| `.env.signaling` | WebRTC signaling: Redis, Vault, JWT | `signaling-server` container |
| `.env.gstreamer` | Recorder: callback secret, AWS IoT paths | `gstreamer-recorder` container |
| `.env.streamer` | MQTT streamer: broker URL, credentials | `mqtt-streamer` container |

Templates for the per-service `.env` files live in the `caytu-client` app repo — copy them from there, fill them in, keep them out of git.

## Rotation

To rotate a secret:

1. Update the value in `compose/.env.<target>` on your workstation.
2. `caytu-client -t <target> env push`
3. `caytu-client -t <target> restart <affected-service>` (or `deploy` if you also want a fresh image).

Container env vars are set at start time — a live container will not pick up a changed env file.

## What about Vault?

The optional `vault` service (behind `--profile vault`) runs in **dev mode** with an in-memory backend and a root token of `root`. That's fine for local development where the signaling server or backend want a token endpoint to poke against, but do not use it as a production secret store.

If you need a hardened secret store in production, either:

- Point services at your existing Vault / AWS Secrets Manager / GCP Secret Manager instance and pass the credentials via `.env.<target>`, **or**
- Provision a real Vault (out of scope for this repo) and point services at it via `VAULT_ADDR` + `VAULT_TOKEN`.

## What lives on the remote host

After `env push`:

```
/opt/caytu-client/compose/
  .env.<target>            # mode 600, owner deploy user
  .env.backend             # mode 600, owner deploy user
  .env.frontend            # …
  nginx/
  monitoring/
  backup/
  docker-compose*.yml
```

The deploy user is the one who ran `bootstrap.sh` (typically `ubuntu` on AWS/GCP Ubuntu images). Rotate the SSH key that reaches this user as part of your regular access review.

## In CI

For CI/CD, put secrets in GitHub Actions Secrets (or equivalent) and render `.env.<target>` at pipeline time before `caytu-client env push`. Do not check the file in, even encrypted.
