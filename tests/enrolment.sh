#!/usr/bin/env bash
# Exercises enroll_self against a scripted platform, no EC2 instance needed.
# Run with: bash tests/enrolment.sh
#
# Outside scripts/ on purpose: Publish-agent tars that directory onto every
# customer machine.
set -uo pipefail
mkdir -p "${TMPDIR:-/tmp}/caytu-enrol-test"

D="$(dirname "$(readlink -f "$0")")"
SRC="$(dirname "$D")"
PASS=0; FAIL=0

check() { # name expected actual
  if [[ "$2" == "$3" ]]; then
    printf '  PASS  %s\n' "$1"; PASS=$((PASS+1))
  else
    printf '  FAIL  %s\n        expected %s, got %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1))
  fi
}

setup() { # port -> fresh sandbox
  rm -rf "${TMPDIR:-/tmp}/caytu-enrol-test/sandbox"; mkdir -p "${TMPDIR:-/tmp}/caytu-enrol-test/sandbox/compose"
  cp -r "$SRC/scripts" "${TMPDIR:-/tmp}/caytu-enrol-test/sandbox/scripts"
  : > "${TMPDIR:-/tmp}/caytu-enrol-test/sandbox/compose/.env.onprem"
}

start_fake() { # plan countfile port
  # Detached from this substitution's stdout, or $( ) waits for the server to exit.
  python3 "$D/fake-platform.py" "$3" "$1" "$2" >/dev/null 2>&1 & echo $!
  for _ in $(seq 40); do
    curl -sf -m 1 "http://127.0.0.1:$3/latest/dynamic/instance-identity/document" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
}

run_enrol() { # port [extra env]
  ( cd "${TMPDIR:-/tmp}/caytu-enrol-test/sandbox" && \
    CAYTU_IMDS_URL="http://127.0.0.1:$1" \
    CAYTU_PLATFORM_URL="http://127.0.0.1:$1" \
    CAYTU_INSTANCE_ID="${INSTANCE_ID-6a7d802c12e201c214b61aeb}" \
    CAYTU_DEPLOYMENT_FILE="${DEPLOY_FILE-${TMPDIR:-/tmp}/caytu-enrol-test/sandbox/deployment.env}" \
    CAYTU_ENROLL_ATTEMPTS="${ATTEMPTS-3}" \
    bash scripts/caytu-client --target onprem enroll-self > "${TMPDIR:-/tmp}/caytu-enrol-test/out.txt" 2>&1 )
  echo $?
}

echo
echo "1. a transient failure is retried, then succeeds"
setup; pid=$(start_fake "503,503,200" "${TMPDIR:-/tmp}/caytu-enrol-test/n.txt" 18081)
INSTANCE_ID=6a7d802c12e201c214b61aeb rc=$(run_enrol 18081)
kill "$pid" 2>/dev/null
check "exits 0" "0" "$rc"
check "made 3 attempts" "3" "$(cat "${TMPDIR:-/tmp}/caytu-enrol-test/n.txt" 2>/dev/null)"
check "stored the credential" "tok-abc" "$(grep -oP '(?<=^CAYTU_METERING_TOKEN=).*' "${TMPDIR:-/tmp}/caytu-enrol-test/sandbox/compose/.env.onprem" 2>/dev/null)"
# Silent when wrong: the deployment reports to the platform named here, so a
# stale production default means a 404 nobody sees and no invitation.
check "reports to the platform it enrolled with" "http://127.0.0.1:18081" "$(grep -oP '(?<=^CAYTU_BILLINGS_URL=).*' "${TMPDIR:-/tmp}/caytu-enrol-test/sandbox/compose/.env.onprem" 2>/dev/null)"

echo
echo "2. a refusal is final and is NOT retried"
setup; pid=$(start_fake "403,403,403" "${TMPDIR:-/tmp}/caytu-enrol-test/n.txt" 18082)
rc=$(run_enrol 18082)
kill "$pid" 2>/dev/null
check "exits non-zero" "1" "$rc"
check "made exactly 1 attempt" "1" "$(cat "${TMPDIR:-/tmp}/caytu-enrol-test/n.txt" 2>/dev/null)"
grep -q "launched too long ago" "${TMPDIR:-/tmp}/caytu-enrol-test/out.txt"; check "repeats the platform's reason" "0" "$?"
grep -q "will not fix itself" "${TMPDIR:-/tmp}/caytu-enrol-test/out.txt"; check "says it is not worth retrying" "0" "$?"

echo
echo "3. rate limiting is a hiccup, not a refusal"
setup; pid=$(start_fake "429,200" "${TMPDIR:-/tmp}/caytu-enrol-test/n.txt" 18083)
rc=$(run_enrol 18083)
kill "$pid" 2>/dev/null
check "exits 0" "0" "$rc"
check "retried past the 429" "2" "$(cat "${TMPDIR:-/tmp}/caytu-enrol-test/n.txt" 2>/dev/null)"

echo
echo "4. gives up after the attempt budget rather than looping forever"
setup; pid=$(start_fake "503,503,503,503,503" "${TMPDIR:-/tmp}/caytu-enrol-test/n.txt" 18084)
ATTEMPTS=3 rc=$(run_enrol 18084)
kill "$pid" 2>/dev/null
check "exits non-zero" "1" "$rc"
check "stopped at the budget" "3" "$(cat "${TMPDIR:-/tmp}/caytu-enrol-test/n.txt" 2>/dev/null)"
grep -q "gave up enrolling" "${TMPDIR:-/tmp}/caytu-enrol-test/out.txt"; check "says it gave up" "0" "$?"

echo
echo "5. the deployment id survives a lost environment (issue #12)"
setup; pid=$(start_fake "200" "${TMPDIR:-/tmp}/caytu-enrol-test/n.txt" 18085)
printf 'CAYTU_INSTANCE_ID=6a7d802c12e201c214b61aeb\nCAYTU_PLATFORM_URL=http://127.0.0.1:18085\n' \
  > "${TMPDIR:-/tmp}/caytu-enrol-test/sandbox/deployment.env"
# Exactly the state after a reboot: nothing in the environment at all.
rc=$( cd "${TMPDIR:-/tmp}/caytu-enrol-test/sandbox" && \
      CAYTU_IMDS_URL="http://127.0.0.1:18085" \
      CAYTU_DEPLOYMENT_FILE="${TMPDIR:-/tmp}/caytu-enrol-test/sandbox/deployment.env" \
      bash scripts/caytu-client --target onprem enroll-self > "${TMPDIR:-/tmp}/caytu-enrol-test/out.txt" 2>&1; echo $? )
kill "$pid" 2>/dev/null
check "enrols anyway" "0" "$rc"
grep -q "6a7d802c12e201c214b61aeb" "${TMPDIR:-/tmp}/caytu-enrol-test/out.txt"; check "found its deployment" "0" "$?"

echo
echo "6. with no environment and no file, it still says what is missing"
setup; pid=$(start_fake "200" "${TMPDIR:-/tmp}/caytu-enrol-test/n.txt" 18086)
rc=$( cd "${TMPDIR:-/tmp}/caytu-enrol-test/sandbox" && \
      CAYTU_IMDS_URL="http://127.0.0.1:18086" \
      CAYTU_DEPLOYMENT_FILE="${TMPDIR:-/tmp}/caytu-enrol-test/sandbox/nope.env" \
      bash scripts/caytu-client --target onprem enroll-self > "${TMPDIR:-/tmp}/caytu-enrol-test/out.txt" 2>&1; echo $? )
kill "$pid" 2>/dev/null
check "exits non-zero" "1" "$rc"
grep -q "CAYTU_INSTANCE_ID is not set" "${TMPDIR:-/tmp}/caytu-enrol-test/out.txt"; check "names what is missing" "0" "$?"

echo
printf '  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
