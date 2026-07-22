# IoT device auth — same shape as single-instance. See
# ../single-instance/iot.tf for a longer explanation of what/why.

locals { iot_enabled = var.enable_iot }

data "aws_iam_policy_document" "iot_thing_policy" {
  count = local.iot_enabled ? 1 : 0

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
  count              = local.iot_enabled ? 1 : 0
  name               = "${var.name_prefix}-${var.environment}-iot-kvs"
  assume_role_policy = data.aws_iam_policy_document.iot_role_alias_assume[0].json
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

data "aws_iot_endpoint" "data" {
  count         = local.iot_enabled ? 1 : 0
  endpoint_type = "iot:Data-ATS"
}
