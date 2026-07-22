# shellcheck shell=bash
# Kubernetes helpers used by aws-cluster, gcp-cluster, and self-managed-k8s
# targets. Thin wrapper over kubectl that picks the right overlay and namespace.

_k8s_overlay_dir() {
  case "$TARGET" in
    self-managed-k8s) echo "$REPO_ROOT/kubernetes/overlays/self-managed" ;;
    aws-cluster)      echo "$REPO_ROOT/kubernetes/overlays/aws-eks" ;;
    gcp-cluster)      echo "$REPO_ROOT/kubernetes/overlays/gcp-gke" ;;
    *) die "k8s verbs only apply to cluster targets (current: $TARGET)" ;;
  esac
}

_k8s_ns() { echo "caytu-client"; }

_kctx_hint() {
  local ctx; ctx="$(kubectl config current-context 2>/dev/null)"
  [[ -n "$ctx" ]] && info "kubectl context: $ctx"
}

k8s_doctor() {
  require_cmd kubectl kustomize
  _kctx_hint
  if kubectl get ns >/dev/null 2>&1; then
    ok "kubectl reaches the cluster"
  else
    warn "kubectl can't reach the cluster — check KUBECONFIG"
  fi
  local overlay; overlay="$(_k8s_overlay_dir)"
  [[ -d "$overlay" ]] && ok "overlay $overlay" || warn "overlay $overlay missing"
  [[ -f "$overlay/secrets.env" ]] && ok "$overlay/secrets.env present" \
    || warn "$overlay/secrets.env missing — copy from secrets.env.example and edit"
}

k8s_diff() {
  local overlay; overlay="$(_k8s_overlay_dir)"
  kubectl diff -k "$overlay" "$@"
}

k8s_apply() {
  local overlay; overlay="$(_k8s_overlay_dir)"
  [[ -f "$overlay/secrets.env" ]] || die "$overlay/secrets.env missing"
  info "applying $overlay…"
  kubectl apply -k "$overlay" "$@"
  ok "applied"
}

k8s_delete() {
  local overlay; overlay="$(_k8s_overlay_dir)"
  confirm "This will delete every caytu-client resource in the cluster. Continue?" || return 0
  kubectl delete -k "$overlay" "$@"
  ok "deleted"
}

k8s_status() {
  local ns; ns="$(_k8s_ns)"
  echo "─── pods ───"
  kubectl -n "$ns" get pods -o wide
  echo
  echo "─── deployments ───"
  kubectl -n "$ns" get deploy,statefulset
  echo
  echo "─── services + ingress ───"
  kubectl -n "$ns" get svc,ingress
}

k8s_logs() {
  local ns; ns="$(_k8s_ns)"
  local svc=${1:-backend}
  kubectl -n "$ns" logs -f -l "app=$svc" --tail=200 --max-log-requests=6
}

k8s_scale() {
  local ns; ns="$(_k8s_ns)"
  local svc=${1:-}; local n=${2:-}
  [[ -n "$svc" && -n "$n" ]] || die "usage: k8s scale <service> <replicas>"
  kubectl -n "$ns" scale "deploy/$svc" --replicas="$n"
}

k8s_rollout() {
  local ns; ns="$(_k8s_ns)"
  local sub=${1:-status}; shift || true
  local svc=${1:-backend}
  case "$sub" in
    status)  kubectl -n "$ns" rollout status  "deploy/$svc" ;;
    restart) kubectl -n "$ns" rollout restart "deploy/$svc" ;;
    undo)    kubectl -n "$ns" rollout undo    "deploy/$svc" ;;
    history) kubectl -n "$ns" rollout history "deploy/$svc" ;;
    *) die "usage: k8s rollout <status|restart|undo|history> [service]" ;;
  esac
}

k8s_exec() {
  local ns; ns="$(_k8s_ns)"
  local svc=${1:-backend}; shift || true
  local pod
  pod="$(kubectl -n "$ns" get pod -l "app=$svc" -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "$pod" ]] || die "no pods for app=$svc"
  kubectl -n "$ns" exec -it "$pod" -- "${@:-sh}"
}

k8s_port_forward() {
  local ns; ns="$(_k8s_ns)"
  local svc=${1:-}; local mapping=${2:-}
  [[ -n "$svc" && -n "$mapping" ]] || die "usage: k8s port-forward <service> <local:remote>"
  kubectl -n "$ns" port-forward "svc/$svc" "$mapping"
}

k8s_secrets_bootstrap() {
  local overlay; overlay="$(_k8s_overlay_dir)"
  if [[ -f "$overlay/secrets.env" ]]; then
    warn "$overlay/secrets.env already exists; skipping"
    return 0
  fi
  cp "$overlay/secrets.env.example" "$overlay/secrets.env"
  ok "created $overlay/secrets.env — fill it in before applying"
}
