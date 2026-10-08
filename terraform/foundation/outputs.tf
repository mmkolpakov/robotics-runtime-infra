output "cluster" {
  description = "Actual provider outputs after accepted deployment, not qualification evidence."
  value = {
    name                       = module.eks.cluster_name
    arn                        = module.eks.cluster_arn
    endpoint                   = module.eks.cluster_endpoint
    certificate_authority_data = module.eks.cluster_certificate_authority_data
  }
}
output "product_identity" {
  description = "Coordinates for product Helm service accounts; no Kubernetes objects are created here."
  value = {
    namespace       = var.product_namespace
    service_account = var.evidence_service_account
    role_arn        = aws_iam_role.pod_identity["evidence"].arn
  }
}
output "retained_storage" {
  description = "Exact-version retention protocol still requires upload/retrieval/Cosign acceptance."
  value = {
    bucket                   = var.evidence_bucket_name
    key_prefix               = var.evidence_key_prefix
    lifecycle_retention_days = var.evidence_retention_days
  }
}
output "repositories" {
  value = { for name, repository in aws_ecr_repository.product : name => repository.repository_url }
}
output "node_configuration" {
  description = "Configuration-only sizing and cohort; never evidence of runtime/provider compatibility."
  value = {
    capacity_type = "ON_DEMAND"
    capacity      = var.node_capacity
    profile       = var.node_profile
  }
}

output "evidence_environment" {
  description = "Standard existing-sink settings for the provisioned prefix; credentials stay in Pod Identity."
  value = {
    AWS_DEFAULT_REGION            = var.aws_region
    EVIDENCE_BUCKET               = var.evidence_bucket_name
    EVIDENCE_PREFIX               = trimsuffix(var.evidence_key_prefix, "/")
    RCLONE_CONFIG_EVIDENCE_REGION = var.aws_region
    RCLONE_S3_NO_CHECK_BUCKET     = "true"
  }
}
