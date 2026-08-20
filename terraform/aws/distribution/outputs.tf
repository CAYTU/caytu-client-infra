output "accounts_granted" {
  description = "Accounts that may pull images and fetch the agent."
  value       = [for c in var.customer_accounts : "${c.label} (${c.account_id})"]
}

output "repositories_shared" {
  description = "Repositories carrying a cross-account pull policy."
  value       = length(var.customer_accounts) > 0 ? var.image_repositories : []
}
