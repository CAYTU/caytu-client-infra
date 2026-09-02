#!/usr/bin/env bash
# The template a customer runs, and the IAM size limits it has to stay under.
#
# Both limits have been hit for real. Inline policies share one 10,240 budget
# across the role, which the checker used to measure one policy at a time, so
# two 5k policies passed here and the customer's stack update failed.
set -uo pipefail
SRC="$(dirname "$(dirname "$(readlink -f "$0")")")"
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
PASS=0; FAIL=0
check() { [[ "$2" == "$3" ]] && { echo "  PASS  $1"; PASS=$((PASS+1)); } || { echo "  FAIL  $1: expected $2, got $3"; FAIL=$((FAIL+1)); }; }

verify() { python3 "$SRC/scripts/verify-cloudformation.py" "$1" >/dev/null 2>&1; echo $?; }

# A policy of roughly $1 characters, as one statement with padded actions.
policy() {
  python3 -c '
import json, sys
n = int(sys.argv[1])
acts, size = [], 0
while size < n:
    acts.append("ec2:Describe%s" % ("x" * 40 + str(len(acts))))
    size = len(json.dumps({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":acts,"Resource":"*"}]}, separators=(",",":")))
print(json.dumps({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":acts,"Resource":"*"}]}, indent=2))' "$1"
}

echo
echo "the access template stays inside the IAM limits"

check "the template we ship passes" 0 "$(verify "$SRC/cloudformation/caytu-provisioner-access.yaml")"

# Two policies that are each fine and together are not. This is the shape that
# reached a customer.
{
  echo 'Resources:'
  echo '  ARole:'
  echo '    Type: AWS::IAM::Role'
  echo '    Properties:'
  echo '      Policies:'
  echo '        - PolicyName: one'
  echo '          PolicyDocument: !Sub |'
  policy 5200 | sed 's/^/            /'
  echo '        - PolicyName: two'
  echo '          PolicyDocument: !Sub |'
  policy 5200 | sed 's/^/            /'
} > "$d/aggregate.yaml"
check "two inline policies over 10,240 together are refused" 1 "$(verify "$d/aggregate.yaml")"

{
  echo 'Resources:'
  echo '  ARole:'
  echo '    Type: AWS::IAM::Role'
  echo '    Properties:'
  echo '      Policies:'
  echo '        - PolicyName: one'
  echo '          PolicyDocument: !Sub |'
  policy 4000 | sed 's/^/            /'
  echo '        - PolicyName: two'
  echo '          PolicyDocument: !Sub |'
  policy 4000 | sed 's/^/            /'
} > "$d/under.yaml"
check "and under it they are accepted" 0 "$(verify "$d/under.yaml")"

{
  echo 'Resources:'
  echo '  APolicy:'
  echo '    Type: AWS::IAM::ManagedPolicy'
  echo '    Properties:'
  echo '      PolicyDocument: !Sub |'
  policy 6300 | sed 's/^/        /'
} > "$d/managed.yaml"
check "a managed policy over 6,144 is refused" 1 "$(verify "$d/managed.yaml")"

echo
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
