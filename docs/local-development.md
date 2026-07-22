# Local development

Runs the whole platform on your laptop, with the caytu-client source tree bind-mounted so backend and frontend hot-reload on save.

## Prerequisites

- Docker Engine + Compose plugin (20.10+ / v2)
- The `caytu-client` repo checked out **next to** this one:
  ```
  ~/Documents/
    ├── caytu-client/            # app source
    └── caytu-client-infra/      # this repo
  ```
  Different location? Override `CAYTU_CLIENT_REPO` in `compose/.env.local`.

## First run

```bash
./scripts/caytu-client install                # optional: puts caytu-client in ~/.local/bin
caytu-client --target local init              # copies .env.example -> .env.local
$EDITOR compose/.env.local                    # at minimum: MINIO creds, INITIAL_ADMIN_EMAIL
caytu-client --target local up --build
```

Then:

- Frontend: <http://localhost:3000>
- Backend:  <http://localhost:5000>
- MinIO console: <http://localhost:9001>
- MongoDB: `mongodb://localhost:27017/caytu?replicaSet=rs0&directConnection=true`

## Everyday verbs

```bash
caytu-client -t local up            # start stack (uses existing images)
caytu-client -t local up --build    # rebuild changed images first
caytu-client -t local logs backend  # tail one service
caytu-client -t local ps            # show status
caytu-client -t local restart backend
caytu-client -t local down          # stop + remove containers (volumes kept)
caytu-client -t local down --volumes  # also wipe volumes
caytu-client -t local exec backend sh
```

## Optional services (compose profiles)

The base stack keeps four services behind profiles so a plain `up` doesn't pull them unless you ask:

```bash
# vector search (MongoDB Community Search sidecar)
COMPOSE_PROFILES=search caytu-client -t local up
# also set MONGOT_ARGS in .env.local so mongod knows about mongot

# self-hosted TURN server
COMPOSE_PROFILES=turn caytu-client -t local up

# Vault dev mode
COMPOSE_PROFILES=vault caytu-client -t local up

# local MQTT broker (mosquitto)
COMPOSE_PROFILES=mqtt-broker caytu-client -t local up

# combine
COMPOSE_PROFILES=search,turn,vault caytu-client -t local up
```

## Editing service code

Backend + frontend + gstreamer-recorder + signaling-server bind-mount their source directories from `${CAYTU_CLIENT_REPO}`. Changes on disk trigger nodemon / next dev / uvicorn --reload. No rebuild needed.

Changing `package.json` / `requirements.txt`? Rebuild:

```bash
caytu-client -t local up --build backend
```

## Add monitoring locally

```bash
caytu-client -t local monitor up   # brings up prometheus, grafana, cadvisor, dozzle
open http://localhost:3005          # grafana, admin / <GRAFANA_ADMIN_PASSWORD>
open http://localhost:8005          # dozzle (live logs)
```
