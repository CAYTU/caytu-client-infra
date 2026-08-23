#!/usr/bin/env bash
# Let one customer account pull our images and fetch the host agent.
#
# This used to be two terraform applies somebody ran on a laptop with a tfvars
# file, which does not survive a second customer. Provisioning already runs with
# our own credentials before it steps into the customer account, and that role
# already holds ecr:SetRepositoryPolicy and s3:PutBucketPolicy on caytu-*, so
# the pipeline can do it itself.
#
# Additive and idempotent on purpose: it reads what is there, adds the account
# if missing, and writes it back. Re-provisioning the same deployment changes
# nothing, and onboarding a second customer does not revoke the first.
set -euo pipefail

ACCOUNT="${1:?usage: grant-customer-artifacts.sh <aws-account-id> [prefix]}"
PREFIX="${2:-caytu-}"
BUCKET="${AGENT_BUCKET:-caytu-cli}"
AGENT_PREFIX="${AGENT_PREFIX:-agent}"
REPOS="${IMAGE_REPOSITORIES:-caytu-client-backend caytu-client-frontend caytu-client-mqtt-streamer caytu-client-gstreamer-recorder caytu-client-signaling-server}"

[[ "$ACCOUNT" =~ ^[0-9]{12}$ ]] || {
  echo "::error::'$ACCOUNT' is not a 12-digit account id"
  exit 1
}

sid="Customer${ACCOUNT}"

# Only a role we created there, never every principal in the account.
cond="$(jq -nc --arg p "arn:aws:iam::${ACCOUNT}:role/${PREFIX}*" \
  '{ArnLike: {"aws:PrincipalArn": $p}}')"

echo "granting ${ACCOUNT} pull on our registries"
for repo in $REPOS; do
  current="$(aws ecr get-repository-policy --repository-name "$repo" \
    --query policyText --output text 2>/dev/null || echo '{"Version":"2012-10-17","Statement":[]}')"

  updated="$(printf '%s' "$current" | jq -c \
    --arg sid "$sid" --arg acct "$ACCOUNT" --argjson cond "$cond" '
      .Statement = ((.Statement // []) | map(select(.Sid != $sid))) + [{
        Sid: $sid,
        Effect: "Allow",
        Principal: { AWS: ("arn:aws:iam::" + $acct + ":root") },
        Action: [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:DescribeImages",
          "ecr:ListImages"
        ],
        Condition: $cond
      }] | .Version = "2012-10-17"')"

  aws ecr set-repository-policy --repository-name "$repo" \
    --policy-text "$updated" >/dev/null
  echo "  $repo"
done

echo "granting ${ACCOUNT} read on ${BUCKET}/${AGENT_PREFIX}/"
current="$(aws s3api get-bucket-policy --bucket "$BUCKET" --query Policy --output text)"

# Refuses rather than guesses. Replacing a bucket policy we could not read would
# take the public apt repository down with it.
printf '%s' "$current" | jq -e '(.Statement // []) | length > 0' >/dev/null || {
  echo "::error::could not read the current policy on ${BUCKET}; refusing to replace it"
  exit 1
}

updated="$(printf '%s' "$current" | jq -c \
  --arg sid "$sid" --arg acct "$ACCOUNT" --argjson cond "$cond" \
  --arg res "arn:aws:s3:::${BUCKET}/${AGENT_PREFIX}/*" '
    .Statement = ((.Statement // []) | map(select(.Sid != $sid))) + [{
      Sid: $sid,
      Effect: "Allow",
      Principal: { AWS: ("arn:aws:iam::" + $acct + ":root") },
      Action: "s3:GetObject",
      Resource: $res,
      Condition: $cond
    }]')"

aws s3api put-bucket-policy --bucket "$BUCKET" --policy "$updated"
echo "  ${BUCKET}"
