mock_provider "aws" {
  override_during = plan
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com", reverse_dns_prefix = "com.amazonaws" }
  }
  mock_data "aws_region" { defaults = { name = "eu-west-1", region = "eu-west-1" } }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "000000000000", arn = "arn:aws:iam::000000000000:role/configuration-only", user_id = "configuration-only" }
  }
  mock_data "aws_iam_session_context" {
    defaults = { issuer_arn = "arn:aws:iam::000000000000:role/configuration-only" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_eks_addon_version" { defaults = { version = "v0.0.0-eksbuild.1" } }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::000000000000:role/configuration-only" }
  }
  mock_resource "aws_eks_cluster" {
    defaults = {
      arn                       = "arn:aws:eks:eu-west-1:000000000000:cluster/configuration-only"
      endpoint                  = "https://configuration-only.invalid"
      certificate_authority     = [{ data = "Y2E=" }]
      kubernetes_network_config = { service_ipv4_cidr = "172.20.0.0/16" }
      vpc_config                = { cluster_security_group_id = "sg-00000000000000001" }
    }
  }
  mock_resource "aws_launch_template" { defaults = { id = "lt-00000000000000000", default_version = 1, latest_version = 1 } }
}
mock_provider "time" { override_during = plan }
mock_provider "tls" { override_during = plan }
mock_provider "cloudinit" { override_during = plan }
mock_provider "null" { override_during = plan }

variables {
  aws_region              = "eu-west-1"
  aws_account_id          = "000000000000"
  cluster_name            = "configuration-only"
  kubernetes_version      = "1.34"
  kubernetes_support_type = "STANDARD"
  cluster_admin_role_arns = ["arn:aws:iam::000000000000:role/configuration-only"]
  availability_zones      = ["eu-west-1a", "eu-west-1b"]
  vpc_cidr                = "10.44.0.0/16"
  private_subnet_cidrs    = ["10.44.0.0/24", "10.44.1.0/24"]
  public_subnet_cidrs     = ["10.44.10.0/24", "10.44.11.0/24"]
  service_ipv4_cidr       = "172.20.0.0/16"
  egress_mode             = "nat-single"
  api_public_access_cidrs = []
  node_capacity           = { min = 1, desired = 1, max = 2 }
  node_profile = {
    architecture        = "x86_64"
    ami_type            = "AL2023_x86_64_STANDARD"
    ami_release_version = "1.34.0-20261001"
    instance_types      = ["m7i.large"]
    root_volume_gib     = 40
  }
  addon_versions = {
    vpc-cni                = "v0.0.0-eksbuild.1"
    kube-proxy             = "v0.0.0-eksbuild.1"
    coredns                = "v0.0.0-eksbuild.1"
    eks-pod-identity-agent = "v0.0.0-eksbuild.1"
    aws-ebs-csi-driver     = "v0.0.0-eksbuild.1"
  }
  control_plane_log_retention_days = 30
  state_bucket_name                = "configuration-only-state"
  evidence_bucket_name             = "configuration-only-evidence"
  evidence_key_prefix              = "retained/"
  evidence_retention_days          = 365
  product_namespace                = "robotics"
  evidence_service_account         = "evidence-sink"
  ecr_repository_names             = ["configuration-only/runtime"]
  tags                             = { Product = "configuration-only", Environment = "configuration-only", Owner = "configuration-only", CostCenter = "configuration-only" }
}
run "configuration_graph" {
  command = plan
  assert {
    condition     = aws_s3_bucket_versioning.evidence.versioning_configuration[0].status == "Enabled" && one(one(aws_s3_bucket_server_side_encryption_configuration.evidence.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "Versioned exact-byte retention must remain encrypted."
  }
  assert {
    condition     = one(one(aws_s3_bucket_lifecycle_configuration.evidence.rule).expiration).days == var.evidence_retention_days && one(one(aws_s3_bucket_lifecycle_configuration.evidence.rule).noncurrent_version_expiration).noncurrent_days == var.evidence_retention_days
    error_message = "Current and noncurrent versions must honor the declared retention."
  }
  assert {
    condition     = alltrue([for statement in jsondecode(aws_iam_role_policy.evidence.policy).Statement : statement.Effect != "Allow" || !contains(statement.Action, "s3:DeleteObjectVersion")]) && length([for statement in jsondecode(aws_iam_role_policy.evidence.policy).Statement : statement if statement.Effect == "Deny" && contains(statement.Action, "s3:DeleteObjectVersion")]) == 1
    error_message = "Uploader permissions must not authorize deleting retained object versions."
  }
  assert {
    condition     = contains(flatten([for statement in jsondecode(aws_iam_role_policy.evidence.policy).Statement : statement.Action if statement.Effect == "Allow"]), "s3:GetObjectVersion")
    error_message = "The existing verifier must be able to fetch exact object versions."
  }
  assert {
    condition     = one(jsondecode(aws_iam_role.pod_identity["evidence"].assume_role_policy).Statement).Condition.StringEquals["aws:RequestTag/eks-cluster-arn"] == local.cluster_arn && one(jsondecode(aws_iam_role.pod_identity["evidence"].assume_role_policy).Statement).Condition.StringEquals["aws:RequestTag/kubernetes-service-account"] == var.evidence_service_account
    error_message = "Evidence credentials must be bound to the declared cluster and service account."
  }

  assert {
    condition     = contains(flatten([for statement in jsondecode(aws_iam_role_policy.evidence.policy).Statement : statement.Action if statement.Effect == "Allow"]), "s3:GetBucketVersioning") && output.evidence_environment.EVIDENCE_PREFIX == trimsuffix(var.evidence_key_prefix, "/") && output.evidence_environment.RCLONE_S3_NO_CHECK_BUCKET == "true"
    error_message = "The unchanged sink needs bucket-versioning observation and a preprovisioned canonical prefix."
  }
}
run "endpoint_configuration_graph" {
  command = plan
  variables {
    egress_mode         = "endpoints"
    public_subnet_cidrs = []
  }
}
run "retention_zero" {
  command = plan
  variables {
    evidence_retention_days = 0
  }
  expect_failures = [var.evidence_retention_days]
}

run "retention_fraction" {
  command = plan
  variables {
    evidence_retention_days = 1.5
  }
  expect_failures = [var.evidence_retention_days]
}

run "shared_state_bucket" {
  command = plan
  variables {
    evidence_bucket_name = "configuration-only-state"
  }
  expect_failures = [var.evidence_bucket_name]
}

run "unrestricted_api" {
  command = plan
  variables {
    api_public_access_cidrs = ["0.0.0.0/0"]
  }
  expect_failures = [var.api_public_access_cidrs]
}

run "invalid_capacity" {
  command = plan
  variables {
    node_capacity = { min = 2, desired = 1, max = 2 }
  }
  expect_failures = [var.node_capacity]
}

run "fractional_capacity" {
  command = plan
  variables {
    node_capacity = { min = 1, desired = 1.5, max = 2 }
  }
  expect_failures = [var.node_capacity]
}

run "missing_az" {
  command = plan
  variables {
    availability_zones   = ["eu-west-1a"]
    private_subnet_cidrs = ["10.44.0.0/24"]
    public_subnet_cidrs  = ["10.44.10.0/24"]
  }
  expect_failures = [var.availability_zones]
}

run "unknown_egress" {
  command = plan
  variables {
    egress_mode = "automatic"
  }
  expect_failures = [var.egress_mode]
}

run "traversing_prefix" {
  command = plan
  variables {
    evidence_key_prefix = "../retained/"
  }
  expect_failures = [var.evidence_key_prefix]
}

run "unsafe_namespace" {
  command = plan
  variables {
    product_namespace = "robotics/admin"
  }
  expect_failures = [var.product_namespace]
}

run "missing_cost_owner" {
  command = plan
  variables {
    tags = { Product = "configuration-only", Environment = "configuration-only", Owner = "", CostCenter = "" }
  }
  expect_failures = [var.tags]
}

run "unpinned_addons" {
  command = plan
  variables {
    addon_versions = { vpc-cni = "latest" }
  }
  expect_failures = [var.addon_versions]
}

run "unqualified_gpu" {
  command = plan
  variables {
    node_profile = { architecture = "x86_64", ami_type = "AL2023_x86_64_NVIDIA", ami_release_version = "1.34.0-20261001", instance_types = ["g6.xlarge"], root_volume_gib = 40 }
  }
  expect_failures = [var.node_profile]
}

run "unpinned_ami" {
  command = plan
  variables {
    node_profile = { architecture = "x86_64", ami_type = "AL2023_x86_64_STANDARD", ami_release_version = "latest", instance_types = ["m7i.large"], root_volume_gib = 40 }
  }
  expect_failures = [var.node_profile]
}

run "reject_equivalent_unrestricted_api" {
  command = plan
  variables { api_public_access_cidrs = ["1.2.3.4/0"] }
  expect_failures = [var.api_public_access_cidrs]
}
