# The certificate the load balancer serves.
#
# Created in the cluster's own account and region, because that is where an ALB
# reads it from. Validated by DNS in our zone, through the aws.dns provider, so
# a cluster in a customer account still gets a caytu.link name without that
# account being able to touch the zone.
#
# The record pointing at the load balancer is not here. That balancer is created
# by the ingress controller after the manifests are applied, so Terraform cannot
# know its name during this apply. The workflow writes it afterwards.

locals {
  # An explicit arn wins. Otherwise create one, but only if there is a name to
  # put on it.
  create_certificate = var.certificate_arn == "" && var.domain_name != ""
  certificate_arn    = var.certificate_arn != "" ? var.certificate_arn : (local.create_certificate ? aws_acm_certificate_validation.this[0].certificate_arn : "")
}

data "aws_route53_zone" "this" {
  count    = local.create_certificate ? 1 : 0
  provider = aws.dns
  name     = "${var.route53_zone_name}."
}

resource "aws_acm_certificate" "this" {
  count             = local.create_certificate ? 1 : 0
  domain_name       = var.domain_name
  validation_method = "DNS"

  # Replacing a certificate in use by a live balancer takes the site down.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "validation" {
  # One record per name on the certificate. A single name today, but writing it
  # this way means adding one later does not need a rewrite.
  for_each = local.create_certificate ? {
    for o in aws_acm_certificate.this[0].domain_validation_options : o.domain_name => {
      name   = o.resource_record_name
      type   = o.resource_record_type
      record = o.resource_record_value
    }
  } : {}

  provider = aws.dns
  zone_id  = data.aws_route53_zone.this[0].zone_id
  name     = each.value.name
  type     = each.value.type
  records  = [each.value.record]
  ttl      = 60

  # The zone is ours and long-lived, so a leftover record from an earlier build
  # of the same name must be replaced rather than collided with.
  allow_overwrite = true
}

# Waits for AWS to see the record. Without this the cluster comes up with a
# certificate that is still pending and the ingress serves nothing.
resource "aws_acm_certificate_validation" "this" {
  count                   = local.create_certificate ? 1 : 0
  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}
