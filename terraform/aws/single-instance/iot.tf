# AWS IoT device-auth wiring for STREAMING_PROVIDER=kvs.
#
# What this creates:
#   1. A generic IoT policy allowing publish/subscribe on the device's own topics
#      and Kinesis Video signaling as the master or viewer.
#   2. An IAM role assumable by IoT certificates (via the role alias).
#   3. A role alias pointing at that role — devices reference the alias, not
#      the raw role ARN, so we can rotate without re-provisioning certs.
#
# What this does NOT create:
#   * IoT Things per device — those are per-camera / per-robot and belong to
#     device provisioning workflows, not platform infra.
#   * X.509 certs — likewise per-device.
#   * KVS signaling channels — created per-camera by the app.

locals {
  iot_enabled = var.enable_iot
}

# --- Policy attached to device certificates ---------------------------------
data "aws_iam_policy_document" "iot_thing_policy" {
  count = local.iot_enabled ? 1 : 0

  # Basic MQTT plane
  statement {
    actions   = ["iot:Connect"]
    resources = ["arn:aws:iot:${var.region}:${data.aws_caller_identity.current.account_id}:client/$${iot:Certificate.Subject.CommonName}"]
  }
  statement {
    actions = ["iot:Publish", "iot:Receive"]
    resources = [
      "arn:aws:iot:${var.region}:${data.aws_caller_identity.current.account_id}:topic/$${iot:Certificate.Subject.CommonName}/*",
      "arn:aws:iot:${var.region}:${data.aws_caller_identity.current.account_id}:topic/caytu/*"
    ]
  }
  statement {
    actions = ["iot:Subscribe"]
    resources = [
      "arn:aws:iot:${var.region}:${data.aws_caller_identity.current.account_id}:topicfilter/$${iot:Certificate.Subject.CommonName}/*",
      "arn:aws:iot:${var.region}:${data.aws_caller_identity.current.account_id}:topicfilter/caytu/*"
    ]
  }

  # Credential-vending for KVS access
  statement {
    actions   = ["iot:AssumeRoleWithCertificate"]
    resources = [aws_iot_role_alias.kvs[0].arn]
  }
}

resource "aws_iot_policy" "device" {
  count  = local.iot_enabled ? 1 : 0
  name   = "${var.name_prefix}-${var.environment}-device"
  policy = data.aws_iam_policy_document.iot_thing_policy[0].json
}

# --- IAM role for KVS via IoT role alias -------------------------------------
data "aws_iam_policy_document" "iot_role_alias_assume" {
  count = local.iot_enabled ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["credentials.iot.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "iot_kvs" {
  count                = local.iot_enabled ? 1 : 0
  name                 = "${var.name_prefix}-${var.environment}-iot-kvs"
  assume_role_policy   = data.aws_iam_policy_document.iot_role_alias_assume[0].json
  permissions_boundary = var.iam_permissions_boundary != "" ? var.iam_permissions_boundary : null
}

data "aws_iam_policy_document" "iot_kvs" {
  count = local.iot_enabled ? 1 : 0
  statement {
    actions = [
      "kinesisvideo:DescribeSignalingChannel",
      "kinesisvideo:GetSignalingChannelEndpoint",
      "kinesisvideo:GetIceServerConfig",
      "kinesisvideo:ConnectAsMaster",
      "kinesisvideo:ConnectAsViewer",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "iot_kvs" {
  count  = local.iot_enabled ? 1 : 0
  name   = "kvs"
  role   = aws_iam_role.iot_kvs[0].id
  policy = data.aws_iam_policy_document.iot_kvs[0].json
}

resource "aws_iot_role_alias" "kvs" {
  count               = local.iot_enabled ? 1 : 0
  alias               = "${var.name_prefix}-${var.environment}-kvs"
  role_arn            = aws_iam_role.iot_kvs[0].arn
  credential_duration = var.iot_role_alias_ttl_seconds
}

# --- Data endpoint used by devices to reach the IoT data plane ---------------
data "aws_iot_endpoint" "data" {
  count         = local.iot_enabled ? 1 : 0
  endpoint_type = "iot:Data-ATS"
}

data "aws_iot_endpoint" "credentials" {
  count         = local.iot_enabled ? 1 : 0
  endpoint_type = "iot:CredentialProvider"
}
