output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_region" {
  value = var.region
}

locals {
  # An empty profile means environment credentials, which is what a runner has.
  # Naming a profile there sends the CLI looking for a file that is not present.
  kubeconfig_command = join(" ", compact([
    "aws eks update-kubeconfig",
    var.aws_profile != "" ? "--profile ${var.aws_profile}" : "",
    "--region ${var.region}",
    "--name ${module.eks.cluster_name}",
  ]))
}

output "kubeconfig_command" {
  description = "Run this to add the cluster to your local kubeconfig"
  value       = local.kubeconfig_command
}

output "ecr_registry" {
  value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

output "ecr_repository_uris" {
  value = { for name, repo in aws_ecr_repository.svc : name => repo.repository_url }
}

output "iot_data_endpoint" {
  value = var.enable_iot ? data.aws_iot_endpoint.data[0].endpoint_address : ""
}

output "iot_role_alias" {
  value = var.enable_iot ? aws_iot_role_alias.kvs[0].alias : ""
}

output "backup_bucket" {
  value = var.create_backup_bucket ? aws_s3_bucket.backups[0].id : ""
}

output "irsa_backend_role_arn" {
  description = "Annotate the 'backend' ServiceAccount with this to give pods KVS + IoT access without static creds"
  value       = aws_iam_role.app_backend.arn
}

output "irsa_backup_role_arn" {
  description = "Annotate the 'backup' ServiceAccount (CronJob) with this to write to the backup bucket"
  value       = var.create_backup_bucket ? aws_iam_role.backup[0].arn : ""
}

output "alb_controller_role_arn" {
  description = "IRSA role for aws-load-balancer-controller. Used in the helm install command below."
  value       = aws_iam_role.alb_controller.arn
}

output "helm_commands" {
  description = "Post-apply commands: install ALB controller + metrics-server. Copy/paste."
  value       = <<-EOT

    # 1. Configure kubectl:
    ${local.kubeconfig_command}

    # 2. Install AWS Load Balancer Controller:
    helm repo add eks https://aws.github.io/eks-charts
    helm repo update
    helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \\
      -n kube-system \\
      --set clusterName=${module.eks.cluster_name} \\
      --set serviceAccount.create=true \\
      --set serviceAccount.name=aws-load-balancer-controller \\
      --set serviceAccount.annotations."eks\\.amazonaws\\.com/role-arn"=${aws_iam_role.alb_controller.arn} \\
      --set region=${var.region} \\
      --set vpcId=${module.vpc.vpc_id}

    # 3. metrics-server:
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

    # 4. Then deploy the app:
    cd kubernetes/overlays/aws-eks
    cp secrets.env.example secrets.env && $EDITOR secrets.env
    $EDITOR kustomization.yaml   # replace <ACCOUNT>, <REGION>, cert ARN, hostname
    caytu-client -t aws-cluster k8s apply
  EOT
}
