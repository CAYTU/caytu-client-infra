#!/usr/bin/env bash
# When a deployment is called running, and what may not hold that up.
#
# A site sat at "Stack running" for three hours while it served perfectly: the
# report came after the basemap, and the basemap is an optional quarter of a
# gigabyte fetched over the customer's link.
set -uo pipefail
cd "$(dirname "$0")/.."
P=0; F=0
ok()  { echo "  PASS  $1"; P=$((P+1)); }
bad() { echo "  FAIL  $1"; F=$((F+1)); }

CLI=scripts/caytu-client

echo
echo "the deployment is called running as soon as the stack is up"
python3 - "$CLI" <<'PY' && ok "the running report comes before the basemap" || bad "the basemap still gates the running report"
import sys
s = open(sys.argv[1]).read()
running = s.find('{status:"running", provisioningPercent:100')
basemap = s.find('report_step "$env_file" "$id" "basemap"')
sys.exit(0 if -1 not in (running, basemap) and running < basemap else 1)
PY

echo
echo "and the basemap cannot hold provisioning up"
grep -q 'sync_cmd=(timeout "${PMTILES_SYNC_TIMEOUT:-1200}"' "$CLI" \
  && ok "a stalled download is bounded" || bad "nothing bounds the download"
# In-process, a `die` inside the sync ended the agent, and the record then sits
# above 0% where no agent picks it up again.
grep -q 'sync_cmd=("$SCRIPT_PATH" -t "$TARGET" tiles sync --set-env)' "$CLI" \
  && ok "it runs as its own process" || bad "it still runs in the agent's own shell"

echo
echo "the daily build is found on a busybox host"
# Alpine is the on-prem case, and its date rejects GNU's "-1 day" outright, so
# the search walked sixty days, found nothing, and every such site came up with
# no basemap at all.
grep -q 'date -u -d @\\\$(( \\\$(date -u +%s) - i \* 86400 ))' "$CLI" \
  && ok "the epoch fallback is in the extract script" || bad "no busybox fallback"

if command -v busybox >/dev/null 2>&1; then
  busybox sh -c '
    i=1
    d=$(date -u -d "-$i day" +%Y%m%d 2>/dev/null) \
      || d=$(date -u -d @$(( $(date -u +%s) - i * 86400 )) +%Y%m%d 2>/dev/null) \
      || d=""
    [ -n "$d" ]' \
    && ok "and busybox resolves a date with it" || bad "busybox still resolves nothing"
else
  echo "  SKIP  busybox is not installed here"
fi

bash -n "$CLI" 2>/dev/null && ok "the cli still parses" || bad "the cli still parses"

printf '\n  %d passed, %d failed\n\n' "$P" "$F"
[ "$F" -eq 0 ]
