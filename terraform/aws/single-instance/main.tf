data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# Networking — reuse the default VPC unless the operator points elsewhere
# -----------------------------------------------------------------------------
data "aws_vpc" "default" {
  count   = var.vpc_id == "" ? 1 : 0
  default = true
}

data "aws_vpc" "chosen" {
  count = var.vpc_id != "" ? 1 : 0
  id    = var.vpc_id
}

locals {
  vpc_id = var.vpc_id != "" ? data.aws_vpc.chosen[0].id : data.aws_vpc.default[0].id
}

data "aws_subnets" "default" {
  count = var.subnet_id == "" ? 1 : 0
  filter {
    name   = "vpc-id"
    values = [local.vpc_id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

locals {
  subnet_id = var.subnet_id != "" ? var.subnet_id : data.aws_subnets.default[0].ids[0]
}

# -----------------------------------------------------------------------------
# SSH key pair
# -----------------------------------------------------------------------------
resource "tls_private_key" "generated" {
  count     = var.ssh_public_key == "" ? 1 : 0
  algorithm = "ED25519"
}

resource "local_sensitive_file" "generated_key" {
  count           = var.ssh_public_key == "" ? 1 : 0
  content         = tls_private_key.generated[0].private_key_openssh
  filename        = var.ssh_key_output_path
  file_permission = "0600"
}

resource "aws_key_pair" "this" {
  key_name   = "${var.name_prefix}-${var.environment}"
  public_key = var.ssh_public_key != "" ? var.ssh_public_key : tls_private_key.generated[0].public_key_openssh
}

# -----------------------------------------------------------------------------
# Security group
# -----------------------------------------------------------------------------
resource "aws_security_group" "this" {
  name        = "${var.name_prefix}-${var.environment}"
  description = "caytu-client single-instance host"
  vpc_id      = local.vpc_id

  dynamic "ingress" {
    for_each = length(var.operator_ssh_cidrs) > 0 ? [1] : []
    content {
      description = "SSH from operator"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.operator_ssh_cidrs
    }
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.public_http_cidrs
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.public_http_cidrs
  }

  dynamic "ingress" {
    for_each = var.enable_turn_ports ? [1] : []
    content {
      description = "TURN"
      from_port   = 3478
      to_port     = 3478
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  dynamic "ingress" {
    for_each = var.enable_turn_ports ? [1] : []
    content {
      description = "TURN UDP"
      from_port   = 3478
      to_port     = 3478
      protocol    = "udp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  dynamic "ingress" {
    for_each = var.enable_turn_ports ? [1] : []
    content {
      description = "TURN TLS"
      from_port   = 5349
      to_port     = 5349
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  dynamic "ingress" {
    for_each = var.enable_turn_ports ? [1] : []
    content {
      description = "TURN media"
      from_port   = 49152
      to_port     = 49252
      protocol    = "udp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# -----------------------------------------------------------------------------
# AMI: Ubuntu 24.04 LTS, arch-matched
# -----------------------------------------------------------------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name = "name"
    values = [
      "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-${var.instance_arch}-server-*"
    ]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# -----------------------------------------------------------------------------
# IAM: instance profile with ECR pull + IoT + KVS + S3-backup permissions
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "instance_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${var.name_prefix}-${var.environment}-instance"
  assume_role_policy = data.aws_iam_policy_document.instance_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

data "aws_iam_policy_document" "instance_kvs_iot" {
  statement {
    sid    = "KvsSignaling"
    effect = "Allow"
    actions = [
      "kinesisvideo:DescribeSignalingChannel",
      "kinesisvideo:GetSignalingChannelEndpoint",
      "kinesisvideo:GetIceServerConfig",
      "kinesisvideo:ConnectAsMaster",
      "kinesisvideo:ConnectAsViewer",
      "kinesisvideo:CreateSignalingChannel",
      "kinesisvideo:ListSignalingChannels",
      "kinesisvideo:DeleteSignalingChannel",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "IotDataPlane"
    effect = "Allow"
    actions = [
      "iot:Connect",
      "iot:Publish",
      "iot:Subscribe",
      "iot:Receive",
      "iot:DescribeEndpoint",
      "iot:AssumeRoleWithCertificate",
      "iot:CreateThing",
      "iot:DescribeThing",
      "iot:ListThings",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "instance_kvs_iot" {
  name   = "${var.name_prefix}-${var.environment}-kvs-iot"
  policy = data.aws_iam_policy_document.instance_kvs_iot.json
}

resource "aws_iam_role_policy_attachment" "instance_kvs_iot" {
  role       = aws_iam_role.instance.name
  policy_arn = aws_iam_policy.instance_kvs_iot.arn
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name_prefix}-${var.environment}-instance"
  role = aws_iam_role.instance.name
}

# -----------------------------------------------------------------------------
# EC2 + Elastic IP
# -----------------------------------------------------------------------------
resource "aws_instance" "this" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = aws_key_pair.this.key_name
  subnet_id     = local.subnet_id

  vpc_security_group_ids = [aws_security_group.this.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  root_block_device {
    volume_size = var.root_volume_size_gb
    volume_type = var.root_volume_type
    encrypted   = true
  }

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 2
    http_endpoint               = "enabled"
  }

  # bootstrap.sh is idempotent so it's safe to include as user_data. Operators
  # who need something different should pass user_data via a tfvars override.
  # Passing the deployment id and platform URL is what turns this from "a machine
  # with docker on it" into a deployment that finishes itself. Both are readable
  # by anything on the box and neither is a secret: the credential is issued
  # against the identity document AWS signs, not against anything written here.
  # The script is carried, not fetched. It used to be curl'd from
  # raw.githubusercontent.com, which cannot work: this repository is private, so
  # an unauthenticated fetch gets 404. Every machine ever built this way finished
  # cloud-init seventeen seconds after boot having done nothing, and then sat
  # there as a bare Ubuntu box waiting to enrol forever.
  #
  # Carrying it also removes a boot-time network dependency and pins the script
  # to the commit that provisioned the machine, rather than whatever `main`
  # happened to say at the moment it booted.
  # base64 rather than a nested heredoc. Terraform strips the indentation of a
  # <<- block based on its least-indented line, so embedding the script raw makes
  # both the shebang and the inner terminator depend on how a 7,000-line file
  # happens to be indented. One encoded argument has no such failure mode.
  user_data = <<-EOF
    #!/bin/bash
    set -e
    echo '${base64encode(file("${path.module}/../../../scripts/bootstrap.sh"))}' \
      | base64 -d > /tmp/caytu-bootstrap.sh
    chmod +x /tmp/caytu-bootstrap.sh
    DEPLOY_USER=ubuntu \
      CAYTU_INSTANCE_ID='${var.caytu_instance_id}' \
      CAYTU_PLATFORM_URL='${var.caytu_platform_url}' \
      bash /tmp/caytu-bootstrap.sh
  EOF

  tags = {
    Name = "${var.name_prefix}-${var.environment}"
  }
  
  lifecycle {
    ignore_changes = [
      ami,          # don't churn the box when Canonical publishes a new AMI
      user_data,    # bootstrap runs once; changes shouldn't recreate
    ]
  }
}

resource "aws_eip" "this" {
  instance = aws_instance.this.id
  domain   = "vpc"
  tags = {
    Name = "${var.name_prefix}-${var.environment}"
  }
}
