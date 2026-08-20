# Region the deployment runs in. This access is valid nowhere else.
region = "eu-west-3"

# Who may assume the role. Caytu supplies these.
caytu_principal_arns = [
  "arn:aws:iam::688544396352:role/caytu-provisioning",
]

# Leave empty and Terraform generates one. Read it back with:
#   terraform output -raw external_id
external_id = ""

# Everything Caytu creates here starts with this. Do not widen it.
resource_prefix = "caytu-"

# Only if the DNS zone for this deployment lives in this account.
allow_route53    = false
route53_zone_ids = []
