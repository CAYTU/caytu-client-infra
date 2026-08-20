# Optional Route 53 A record pointing a domain at the instance's Elastic IP.
#
# Two modes, selected by create_route53_zone:
#   false (default) — look up a hosted zone you already own and add one record
#                     to it. Nothing else in the zone is touched.
#   true            — create the hosted zone too. You must then update the
#                     nameservers at your registrar (see the route53_nameservers
#                     output) before the record resolves anywhere.
#
# With enable_route53 = false this file creates nothing at all.
#
# Everything here runs through the aws.dns provider, not the default one. The
# machine can sit in a customer account while the caytu.link record stays ours
# to write.

locals {
  route53_enabled = var.enable_route53 && var.domain_name != ""
}

data "aws_route53_zone" "this" {
  provider     = aws.dns
  count        = local.route53_enabled && !var.create_route53_zone ? 1 : 0
  name         = var.route53_zone_name
  private_zone = false
}

resource "aws_route53_zone" "this" {
  provider = aws.dns
  count    = local.route53_enabled && var.create_route53_zone ? 1 : 0
  name     = var.route53_zone_name
}

locals {
  route53_zone_id = local.route53_enabled ? (
    var.create_route53_zone ? aws_route53_zone.this[0].zone_id : data.aws_route53_zone.this[0].zone_id
  ) : ""
}

# A plain A record, not an alias — alias targets only work for AWS-managed
# endpoints (ALB, CloudFront, S3 website), not a raw EIP on an EC2 instance.
resource "aws_route53_record" "a" {
  provider        = aws.dns
  count           = local.route53_enabled ? 1 : 0
  zone_id         = local.route53_zone_id
  name            = var.domain_name
  type            = "A"
  ttl             = var.route53_record_ttl
  records         = [aws_eip.this.public_ip]
  allow_overwrite = var.route53_allow_overwrite
}
