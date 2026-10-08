variable "aws_region" {
  description = "Approved commercial AWS region; no environment default."
  type        = string
  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", var.aws_region)) && !startswith(var.aws_region, "cn-") && !startswith(var.aws_region, "us-gov-")
    error_message = "Provide an explicit commercial AWS region."
  }
}
variable "aws_account_id" {
  description = "Expected deployment account, checked by the real provider during approved deployment."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "Provide the expected twelve-digit account ID."
  }
}
variable "state_bucket_name" {
  description = "Globally unique state-only bucket name."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "Use a 3–63 character lowercase bucket name without dots."
  }
}
variable "state_keys" {
  description = "Approved state object keys, including bootstrap and foundation state after migration."
  type        = set(string)
  validation {
    condition = length(var.state_keys) > 0 && alltrue([
      for key in var.state_keys : can(regex("^[a-zA-Z0-9/_-]+[.]tfstate$", key)) && !strcontains(key, "..")
    ])
    error_message = "Declare nonempty, nontraversing state keys ending in .tfstate."
  }
}
variable "state_operator_role_arns" {
  description = "Existing approved same-account deployment roles; no credentials are stored here."
  type        = set(string)
  validation {
    condition = length(var.state_operator_role_arns) > 0 && alltrue([
      for arn in var.state_operator_role_arns : startswith(arn, "arn:aws:iam::${var.aws_account_id}:role/")
    ])
    error_message = "Provide existing same-account operator role ARNs."
  }
}
variable "tags" {
  description = "Billing and ownership tags. Product/Environment/Owner/CostCenter are required."
  type        = map(string)
  validation {
    condition = alltrue([
      for key in ["Product", "Environment", "Owner", "CostCenter"] : try(length(trimspace(var.tags[key])) > 0, false)
    ])
    error_message = "Provide nonempty Product, Environment, Owner and CostCenter tags."
  }
}
