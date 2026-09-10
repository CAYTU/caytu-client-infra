#!/usr/bin/env bash
# The storage class retains volumes, so nothing else removes them. Twelve test
# builds once left 48 of them billing.
set -uo pipefail
cd "$(dirname "$0")/.."
P=0; F=0
ok()  { echo "  PASS  $1"; P=$((P+1)); }
bad() { echo "  FAIL  $1"; F=$((F+1)); }
in_file() { grep -q "$2" "$1" && ok "$3" || bad "$3"; }

SC=kubernetes/overlays/aws-eks/storage.yaml
PROV=.github/workflows/Provision-cluster.yml
DEST=.github/workflows/Destroy-cluster.yml

echo
echo "a volume says which deployment it belongs to"
in_file "$SC" 'tagSpecification_1: "caytu:deployment=INSTANCE_ID_PLACEHOLDER"' "the storage class tags what it creates"
in_file "$SC" "reclaimPolicy: Retain" "and still retains on a deleted claim"
in_file "$PROV" 'INSTANCE_ID_PLACEHOLDER|${INSTANCE_ID}|g" storage.yaml' "provisioning fills the tag in"

echo
echo "destroying the deployment removes them"
in_file "$DEST" "tag:caytu:deployment" "the sweep matches that tag"
in_file "$DEST" "Name=status,Values=available" "and only unattached ones"
in_file "$DEST" "delete-volume" "it deletes them"

# An untagged deployment predates this; the sweep must say so, not fail.
grep -A 30 "Remove the volumes the deployment leaves behind" "$DEST" \
  | grep -q "no volumes tagged" && ok "an older deployment is not an error" \
  || bad "an older deployment is not an error"

# zsh does not split an unquoted variable; the loop must not depend on it.
grep -A 40 "Remove the volumes the deployment leaves behind" "$DEST" \
  | grep -q "tr '\\\\t' '\\\\n'" && ok "the id list is split explicitly" \
  || bad "the id list is split explicitly"

python3 -c "import yaml,sys;[yaml.safe_load(open(f)) for f in ['$SC','$PROV','$DEST']]" 2>/dev/null \
  && ok "all three still parse" || bad "all three still parse"

printf '\n  %d passed, %d failed\n\n' "$P" "$F"
[ "$F" -eq 0 ]
