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
variables {
  aws_region               = "eu-west-1"
  aws_account_id           = "000000000000"
  state_bucket_name        = "configuration-only-state"
  state_keys               = ["bootstrap/terraform.tfstate", "foundation/terraform.tfstate"]
  state_operator_role_arns = ["arn:aws:iam::000000000000:role/configuration-only"]
  tags                     = { Product = "configuration-only", Environment = "configuration-only", Owner = "configuration-only", CostCenter = "configuration-only" }
}
run "state_configuration" {
  command = plan
  assert {
    condition     = output.state_backend.use_lockfile && output.state_backend.encrypt && aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "State must remain versioned/encrypted with S3 locking enabled."
  }
  assert {
    condition     = alltrue([for statement in jsondecode(aws_s3_bucket_policy.state.policy).Statement : !contains(try(statement.Action, []), "s3:DeleteObject") || statement.Effect == "Deny" || alltrue([for arn in statement.Resource : endswith(arn, ".tflock")])])
    error_message = "State operators may delete lockfiles, not the managed state objects."
  }
}
run "reject_traversing_state_key" {
  command = plan
  variables { state_keys = ["../foundation.tfstate"] }
  expect_failures = [var.state_keys]
}
run "reject_foreign_operator" {
  command = plan
  variables { state_operator_role_arns = ["arn:aws:iam::999999999999:role/foreign"] }
  expect_failures = [var.state_operator_role_arns]
}
