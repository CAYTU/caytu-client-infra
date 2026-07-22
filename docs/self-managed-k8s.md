# Self-managed Kubernetes

For running the platform on a cluster you own — k3s on a single node or many, RKE2, kubeadm, Rancher, or any existing cluster you have a kubeconfig for. No cloud dependencies.

## Two paths

**Path A — k3s from scratch, single node**

Fastest way to a working cluster. Good for on-prem HA-lite or edge deployments.

```bash
# On the target host:
curl -fsSL https://raw.githubusercontent.com/CAYTU/caytu-client-infra/main/scripts/bootstrap.sh | \
  sudo INSTALL_K3S=1 bash

# The bootstrap script prints exactly how to add worker nodes if you want
# multi-node. Save the K3S_TOKEN and server IP shown.

# Grab the kubeconfig on your workstation:
scp <user>@<host>:~/.kube/config ~/.kube/caytu-cluster
export KUBECONFIG=~/.kube/caytu-cluster
kubectl get nodes
```

**Path B — bring your own kubeconfig**

Already have a cluster (RKE2, kubeadm, existing Rancher/OpenShift/whatever)? Just point `KUBECONFIG` at it and skip the k3s install.

```bash
export KUBECONFIG=~/.kube/my-cluster
kubectl get nodes  # sanity check
```

## Prerequisites (both paths)

Install once, cluster-wide:

```bash
# Ingress controller — nginx-ingress is what the base overlay expects
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer   # or NodePort on bare-metal without a LB

# cert-manager (optional, for automatic TLS via Let's Encrypt)
helm repo add jetstack https://charts.jetstack.io
helm upgrade --install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace --set installCRDs=true
```

## Deploy the app

```bash
cd caytu-client-infra
caytu-client -t self-managed-k8s k8s doctor

# First-time: create secrets.env from the template
caytu-client -t self-managed-k8s k8s secrets-bootstrap
$EDITOR kubernetes/overlays/self-managed/secrets.env

# Also edit the overlay to point at your registry + hostname:
$EDITOR kubernetes/overlays/self-managed/kustomization.yaml
# - update `images:` newName/newTag to your registry
# - update the ingress rule's /spec/rules/0/host to a hostname you can reach

# Push your images to whatever registry you use
docker push myregistry.example.com/caytu-client/backend:<tag>
# ... etc

# For a private registry, create an imagePullSecret and reference it:
kubectl -n caytu-client create secret docker-registry regcred \
  --docker-server=myregistry.example.com \
  --docker-username=... \
  --docker-password=...

# Preview + apply
caytu-client -t self-managed-k8s k8s diff
caytu-client -t self-managed-k8s k8s apply
caytu-client -t self-managed-k8s k8s status
caytu-client -t self-managed-k8s k8s logs backend
```

## Everyday verbs

```bash
caytu-client -t self-managed-k8s k8s status
caytu-client -t self-managed-k8s k8s logs backend
caytu-client -t self-managed-k8s k8s logs signaling-server
caytu-client -t self-managed-k8s k8s scale backend 4
caytu-client -t self-managed-k8s k8s rollout restart backend
caytu-client -t self-managed-k8s k8s rollout undo backend
caytu-client -t self-managed-k8s k8s exec backend           # opens sh in a backend pod
caytu-client -t self-managed-k8s k8s port-forward minio 9001:9001
```

Applying overlay changes (image tags, replicas, patches):

```bash
$EDITOR kubernetes/overlays/self-managed/kustomization.yaml
caytu-client -t self-managed-k8s k8s diff
caytu-client -t self-managed-k8s k8s apply
```

## Storage

Defaults use `local-path` (k3s ships this out of the box — provisions node-local hostPath volumes). This is fine for a single-node cluster and lightly-loaded multi-node clusters where you're OK with pod-to-node affinity. Data is bound to a specific node.

For real HA, install a replicated storage provider and change the storage class in the overlay:

- **Longhorn** — replicated block storage, k8s-native. `helm install longhorn longhorn/longhorn`
- **Rook Ceph** — mature, complex, high overhead
- **NFS / SMB via CSI** — if you already have shared storage

Change all `storageClassName: local-path` references in [kubernetes/overlays/self-managed/kustomization.yaml](../kubernetes/overlays/self-managed/kustomization.yaml) to your class.

## HA MongoDB

The base ships MongoDB as a StatefulSet with `replicas: 1`. For multi-node HA, patch to 3 replicas and adjust the replSet init:

```yaml
# add to overlays/self-managed/kustomization.yaml patches:
- target: { kind: StatefulSet, name: mongodb }
  patch: |-
    - op: replace
      path: /spec/replicas
      value: 3
```

You'll then need to run `rs.reconfig` inside the primary once all 3 pods are up. Consider MongoDB Community Operator for a less manual path.

## TLS

**Let's Encrypt + cert-manager** (public DNS required):

Add to the overlay `patches:`:

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

Create the cluster issuer once:

```yaml
# cluster-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: { name: letsencrypt-prod }
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ops@example.com
    privateKeySecretRef: { name: letsencrypt-prod }
    solvers:
      - http01: { ingress: { class: nginx } }
```

**BYO cert** (internal PKI, self-signed):

```bash
kubectl -n caytu-client create secret tls caytu-tls \
  --cert=fullchain.pem --key=privkey.pem
```

Then add the `tls:` block above without the annotation.

## Backups

The compose backup container doesn't run in the cluster. For k8s, either:

- **CronJob approach**: schedule `mongodump` to S3/GCS/MinIO via a periodic Job (small YAML addition — say the word and I'll add it)
- **MongoDB Community Operator** with `Backup` custom resource
- **Longhorn snapshots** if you use Longhorn storage
- **Velero** for cluster-level backup (includes PV data)

Not shipped in the base — pick what fits your ops.

## Air-gapped

Every image is pulled from a registry. Air-gapped installs need a local registry (`docker-registry`, `harbor`, `sonatype-nexus`) with images loaded via `docker load`. Point the overlay's `images:` at that registry.

Kubernetes itself can also be air-gapped — k3s ships as a single binary + bundled containerd, and both accept private registry mirrors via [`/etc/rancher/k3s/registries.yaml`](https://docs.k3s.io/installation/private-registry).

## Removal

```bash
caytu-client -t self-managed-k8s k8s delete
# This deletes every resource in the caytu-client namespace including PVCs.
# For a partial clean (keep data): kubectl delete deploy,sts,job -n caytu-client --all
```
