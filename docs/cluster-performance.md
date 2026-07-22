# Cluster performance & load-balancing

What's built into the cluster deployments to make them fast and resilient.

## What's on by default

Every app service (`backend`, `frontend`, `signaling-server`, `mqtt-streamer`) in the [Kustomize base](../kubernetes/base/) ships with:

| Feature | Why it matters |
|---|---|
| **HorizontalPodAutoscaler** | Scales replicas on CPU (and memory for backend) 60-70% utilization. Handles bursty load without operator intervention. |
| **PodDisruptionBudget** | Guarantees `minAvailable: 1` during node drains / cluster upgrades — kubectl won't evict your last replica. |
| **topologySpreadConstraints** | Spreads pods across nodes and (on multi-zone clusters) zones. One node/zone loss doesn't take down the app. |
| **podAntiAffinity** (backend) | Extra hint to keep replicas on separate nodes. |
| **Startup probe** | Slow first boots (image pull, JIT) don't kill pods before they're ready. |
| **Rolling update `maxUnavailable: 0`** | Zero-downtime deploys — new pods come up before old ones are torn down. |
| **`preStop` sleep** | Gives in-flight requests (10-30 s) time to drain before SIGKILL. |
| **Session affinity on `signaling-server`** | WebSocket / WebRTC sessions stick to one backend for the connection's lifetime. |

### Per-service tuning

- **backend**: HPA 2 → 10 replicas, targets CPU 70% + memory 75%. Aggressive scale-up (30 s), conservative scale-down (5 min).
- **frontend**: HPA 2 → 8 replicas, CPU 70%. Same behavior.
- **signaling-server**: HPA 2 → 6 replicas, CPU 60% (scales earlier — WebSocket is CPU-bursty). Scale-down window is 10 min because sessions are long-lived.
- **mqtt-streamer**: HPA 2 → 6 replicas, CPU 70%. `preStop: sleep 20` for in-flight MQTT drainage.
- **gstreamer-recorder**: `Recreate` strategy + PDB `maxUnavailable: 0`. One pod owns the recordings PVC; can't run multi-replica without externalizing state.

## Load-balancing per target

### `aws-cluster` (EKS)

- **ALB via AWS Load Balancer Controller** — Layer 7, HTTP/2 to upstream, sticky cookies for 1 hour, 30 s deregistration delay, `/health` path checks every 15 s.
- **ACM cert** on ALB for TLS termination.
- **Cross-zone load balancing** — enabled by default (spread across 2+ AZs when the cluster has multiple zones).
- **No coturn / signaling-server** — KVS + IoT Core replace them.

### `gcp-cluster` (GKE)

- **HTTP(S) Load Balancer via GCE Ingress** — global, backed by a static IP Terraform provisions.
- **FrontendConfig** — TLS policy + HTTP-to-HTTPS redirect (301).
- **BackendConfig on `signaling-server`** — GENERATED_COOKIE session affinity (3 h), 60 s draining, custom `/health` probe.
- **Managed certificate** — Google provisions LE certs automatically once DNS resolves.
- **UDP LoadBalancer on `coturn`** — GKE natively supports UDP LBs.

### `self-managed-k8s`

- **MetalLB** — installs via helm, advertises a LAN IP pool for `type: LoadBalancer`. Without this, `type: LoadBalancer` sits `<pending>` forever on bare-metal. See [../kubernetes/overlays/self-managed/metallb.md](../kubernetes/overlays/self-managed/metallb.md).
- **nginx-ingress** — HTTP/2, keepalives, 100 MB body limit, 1 h read/send timeouts (long-lived WS).
- **`externalTrafficPolicy: Local`** — preserves source IPs, skips the kube-proxy hop, better for rate-limiting + logging.
- **coturn `hostNetwork: true`** — sidesteps the UDP-range LB problem on bare-metal.

## Verifying it's working

```bash
# HPA status — target vs current utilization, current replicas
caytu-client -t <target> k8s status
kubectl -n caytu-client get hpa

# Pod distribution across nodes
kubectl -n caytu-client get pods -o wide --sort-by=.spec.nodeName

# LB / ingress externals
kubectl -n caytu-client get svc,ingress
kubectl -n caytu-client describe ingress caytu-client   # shows the actual LB address

# PDB status during a rolling update
kubectl -n caytu-client get pdb
```

## When you need more

The defaults cover 90% of production workloads for a single-region cluster. Reach for these when you hit their specific triggers:

- **Cluster autoscaler** — nodes autoscale. Already on: EKS node group has `min_size:2, max_size:5`; GKE node pool has `min_node_count:3, max_node_count:10`. Bump in `terraform.tfvars`.
- **Custom metrics HPA** — scale on requests/sec or queue depth, not just CPU. Requires prometheus-adapter or KEDA. Not shipped.
- **Node affinity / taints** — schedule mongo/gstreamer on beefier nodes. Add a nodeSelector in an overlay patch.
- **PriorityClasses** — evict lower-priority workloads first under memory pressure. Add via a base patch if you run other tenants on the cluster.
- **NetworkPolicy** — restrict pod-to-pod traffic (defense-in-depth). Not shipped — needs a CNI that supports it (Calico, Cilium; GKE with `network_policy_config` enabled, EKS with the addon).
- **Service mesh (Istio / Linkerd)** — mutual TLS between pods, per-service tracing, retries/circuit-breakers. Meaningful overhead — only reach for it when the observability wins justify the operational cost.
- **Multi-region** — real story is app-level: run two independent clusters in different regions, front them with a global LB (Route 53, Cloud DNS + external LB), replicate Mongo across regions. Bigger project; not in this repo.

## Anti-patterns to avoid

- **Setting `resources.limits.cpu` too low.** Node CPU throttles the container even when the node has spare capacity. Prefer generous CPU limits + tight memory limits. Our defaults follow this.
- **Removing PDBs to "unblock" a stuck upgrade.** The PDB is the whole point — it's telling you an eviction would break availability. Fix the underlying issue (add replicas, add node capacity).
- **Baking secrets into ConfigMaps** to skip the secretGenerator step. Kubernetes will happily accept it, but `kubectl get cm -o yaml` dumps them in plain text.
- **Turning off `preStop` sleep**. Rolling updates without it kill in-flight requests. The 15-30 s delay is negligible.
- **Setting `externalTrafficPolicy: Cluster` when you need real client IPs**. `Local` is right for ingress; `Cluster` breaks source IP preservation.
