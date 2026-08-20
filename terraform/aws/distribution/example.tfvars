region      = "us-east-1"
aws_profile = "eks-admin"

# One entry per customer account. Empty means nothing is shared, and the agent
# bucket is still locked down.
customer_accounts = [
  # {
  #   account_id = "111122223333"
  #   label      = "joj"
  # },
]
