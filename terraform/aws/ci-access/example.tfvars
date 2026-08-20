region      = "us-east-1"
aws_profile = "eks-admin"

# Same values Provision.yml reads today as secrets.
state_bucket     = "REPLACE-ME"
state_lock_table = ""

# The caytu.link zone, so hosted deployments still get their record.
hosted_dns_zone_ids = []

# Filled in as customers onboard. Each one runs terraform/aws/customer-onboarding
# and sends back its role arn.
customer_role_arns = [
  # "arn:aws:iam::111122223333:role/CaytuProvisioner",
]
