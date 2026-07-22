# Self-managed Kubernetes overlay

Kustomize overlay for `self-managed-k8s` target. Assumes you have a working `kubectl` context — either k3s installed via [bootstrap.sh --install-k3s](../../../scripts/bootstrap.sh), or any other cluster you own (RKE2, kubeadm, Rancher, bare-metal).

## First run

```bash
cd kubernetes/overlays/self-managed
cp secrets.env.example secrets.env
$EDITOR secrets.env

# preview
kubectl kustomize .

# apply
kubectl apply -k .

# watch it come up
kubectl -n caytu-client get pods -w
```

## What this overlay does vs the base

- **Storage class**: sets `local-path` on all PVCs (k3s default). Override in the patches: for other distros.
- **Ingress class**: forces `nginx` (rather than the base's default). Assumes nginx-ingress is installed cluster-wide. Install with `helm install ingress-nginx ingress-nginx/ingress-nginx` if not.
- **Hostname**: overridden here — edit `/spec/rules/0/host` in kustomization.yaml.
- **coturn**: switched to `hostNetwork: true` so the ephemeral UDP range (49152-49252) is reachable without a LoadBalancer that supports UDP.
- **Secrets**: `secretGenerator` reads `secrets.env`, base64-encodes, produces the `caytu-secrets` Secret referenced by every Deployment.

## Prerequisites you install once

```bash
# nginx-ingress (skip if you already have an ingress controller)
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer  # or NodePort on bare-metal

# cert-manager for automatic Let's Encrypt (optional)
helm repo add jetstack https://charts.jetstack.io
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set installCRDs=true
```

## TLS

Two paths, pick one. Both add annotations to the ingress via a patch.

**Let's Encrypt (public DNS required):** use cert-manager. Add to `patches:`:

```yaml
- target: { kind: Ingress, name: caytu-client }
  patch: |-
    - op: add
      path: /metadata/annotations/cert-manager.io~1cluster-issuer
      value: letsencrypt-prod
    - op: add
      path: /spec/tls
      value:
        - hosts: [caytu.example.com]
          secretName: caytu-tls
```

**Bring-your-own cert:**

```bash
kubectl -n caytu-client create secret tls caytu-tls \
  --cert=fullchain.pem --key=privkey.pem
```

Then add the `tls:` block to the ingress patch without the annotation.

## Sizing

Defaults are conservative — good for a 3-node k3s cluster of ~4 vCPU each.

Scale up:

```bash
kubectl -n caytu-client scale deployment backend --replicas=4
kubectl -n caytu-client scale deployment frontend --replicas=3
```

For multi-node MongoDB, bump `replicas: 3` on the StatefulSet and adjust the `replSet` init command. See [self-managed-k8s.md](../../../docs/self-managed-k8s.md).
