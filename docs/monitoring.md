# Monitoring

The monitoring overlay adds five containers to the stack:

| Container | Purpose | Default port |
|---|---|---|
| prometheus | metrics server, 30s scrape, 15d retention | 9095 (bound to 127.0.0.1 on remote) |
| grafana | dashboards | 3005 (bound to 127.0.0.1 on remote) |
| cadvisor | per-container CPU / mem / IO | internal only |
| node-exporter | host CPU / mem / disk / net | 9100 (host network) |
| dozzle | live multi-container logs | 8005 (bound to 127.0.0.1 on remote) |

## Turning it on

```bash
caytu-client -t <target> monitor up      # start
caytu-client -t <target> monitor down    # stop (containers preserved)
```

This flips a state flag so subsequent `up` / `deploy` invocations keep the overlay attached.

## Accessing on remote hosts

Grafana and Dozzle are bound to `127.0.0.1` so you don't put admin surfaces on the public internet. Use an SSH tunnel:

```bash
caytu-client -t ssh monitor tunnel grafana    # open http://localhost:3005
caytu-client -t ssh monitor tunnel dozzle     # open http://localhost:8005
```

Login:

- Grafana: `admin` / value of `GRAFANA_ADMIN_PASSWORD` in `.env.<target>`.
- Dozzle: uses no auth by default (safe because it's on 127.0.0.1). To require login, set `DOZZLE_AUTH_PROVIDER=simple`, `DOZZLE_USERNAME`, `DOZZLE_PASSWORD`.

## Dashboards

Grafana auto-loads dashboards from `compose/monitoring/grafana/provisioning/dashboards/`. Drop JSON dashboard exports there and restart Grafana.

Recommended starters (from grafana.com):

- **1860** Node Exporter Full
- **14282** Docker Container & Host metrics (cAdvisor)
- **13639** cAdvisor exporter
- **2279** Caddy v2 (skip if you use nginx)

## App-side metrics

`prometheus.yml` already scrapes `backend:5000/metrics` and `signaling-server:3001/metrics`. Wire them up on the app side (e.g. `prom-client` in Node) and they'll appear automatically.

## Sizing

Rough numbers for a single-instance deployment:

- ~60 series scraped every 30s
- ~3-5 GB/month of Prometheus TSDB
- Grafana data: a few MB
- cAdvisor + node-exporter: no persistence

Increase retention via `PROMETHEUS_RETENTION_TIME` in `.env.<target>` (default `15d`).
