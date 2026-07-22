# MetalLB — required for `type: LoadBalancer` on bare-metal / k3s

Without MetalLB, `Service.type: LoadBalancer` sits in `<pending>` forever on a
non-cloud cluster. MetalLB gives it life by advertising a pool of IPs from
your LAN.

## Install

```bash
# 1. Install MetalLB (once per cluster)
helm repo add metallb https://metallb.github.io/metallb
helm repo update
helm upgrade --install metallb metallb/metallb -n metallb-system --create-namespace

# 2. Give MetalLB an IP pool from your LAN. Pick a range that's NOT in the
#    DHCP scope — e.g. if your LAN is 192.168.1.0/24 and DHCP hands out
#    .100-.200, use .210-.220.
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: caytu-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.1.210-192.168.1.220
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: caytu-l2
  namespace: metallb-system
spec:
  ipAddressPools: [caytu-pool]
EOF
```

## Wire nginx-ingress to a LoadBalancer

Once MetalLB is running, reinstall (or upgrade) nginx-ingress with
`service.type=LoadBalancer` — MetalLB will assign it an IP from the pool
and the ingress becomes reachable at that IP.

```bash
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer \
  --set controller.service.externalTrafficPolicy=Local  # preserves source IPs
```

`externalTrafficPolicy: Local` is a real perf/security win — pods see the
original client IP, and traffic doesn't get double-hopped through kube-proxy.

## Troubleshooting

- **Service stays `<pending>`**: MetalLB pool isn't in the LAN broadcast domain, or the pool overlaps with used addresses. `kubectl -n metallb-system logs -l app.kubernetes.io/name=metallb -c speaker`
- **Duplicate IP**: something on the LAN is already using an address from the pool. Shrink the range.
- **BGP mode**: for multi-subnet clusters, use MetalLB's BGP mode instead of L2. Requires a BGP-capable router (Cisco/Juniper/pfSense/RouterOS).
