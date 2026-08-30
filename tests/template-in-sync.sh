#!/usr/bin/env bash
# The console ships a copy of the access template. It has to be this one.
#
# The template lives here and the console bundles it into its build, so a change
# here reaches a customer only if somebody remembers to copy it across. Nobody
# always remembers: it has gone stale three times, and the last one cost an
# afternoon because the file a customer downloaded was missing the permission
# the run had just failed on.
#
# Skipped when the console is not checked out beside this repository, so it does
# not fail on a machine that only has one of them.
set -uo pipefail
cd "$(dirname "$0")/.."

HERE="cloudformation/caytu-provisioner-access.yaml"
THERE="${CONSOLE_REPO:-../Caytu-Infra}/web-v2/src/features/billings/assets/caytu-provisioner-access.yaml"

if [ ! -f "$THERE" ]; then
  echo "  SKIP  the console is not checked out at ${THERE%/web-v2/*}"
  exit 0
fi

if diff -q "$HERE" "$THERE" >/dev/null; then
  echo "  PASS  the console ships this template"
  exit 0
fi

echo "  FAIL  the console ships a different template"
echo
echo "  What a customer downloads is not what this repository says they should."
echo "  Copy it across:"
echo
echo "    cp $HERE \\"
echo "       $THERE"
echo
diff "$HERE" "$THERE" | head -20
exit 1
