variable "aws_region" {
  description = "Explicit commercial AWS region."
  type        = string
  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", var.aws_region)) && !startswith(var.aws_region, "cn-") && !startswith(var.aws_region, "us-gov-")
    error_message = "Provide an explicit commercial region."
  }
}

variable "aws_account_id" {
  description = "Expected account; no credentials are provided."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "Provide the expected twelve-digit account ID."
  }
}

variable "cluster_name" {
  description = "Explicit product/environment cluster name."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,39}$", var.cluster_name))
    error_message = "Use a 3–40 character lowercase cluster name."
  }
}

variable "kubernetes_version" {
  description = "Approved EKS minor; actual availability/support require AWS acceptance."
  type        = string
  validation {
    condition     = can(regex("^1[.][0-9]{2}$", var.kubernetes_version))
    error_message = "Declare a Kubernetes 1.xx minor."
  }
}

variable "kubernetes_support_type" {
  description = "Explicit support choice and its upgrade/cost tradeoff."
  type        = string
  validation {
    condition     = contains(["STANDARD", "EXTENDED"], var.kubernetes_support_type)
    error_message = "Choose STANDARD or EXTENDED support."
  }
}

variable "cluster_admin_role_arns" {
  description = "Existing approved same-account administrator roles."
  type        = set(string)
  validation {
    condition     = length(var.cluster_admin_role_arns) > 0 && alltrue([for arn in var.cluster_admin_role_arns : startswith(arn, "arn:aws:iam::${var.aws_account_id}:role/")])
    error_message = "Declare existing same-account administrator roles."
  }
}

variable "availability_zones" {
  description = "Reviewed AZ/subnet capacity; at least two distinct AZs."
  type        = list(string)
  validation {
    condition     = length(var.availability_zones) >= 2 && length(distinct(var.availability_zones)) == length(var.availability_zones) && alltrue([for az in var.availability_zones : startswith(az, var.aws_region)])
    error_message = "Declare at least two distinct AZs in the selected region."
  }
}

variable "vpc_cidr" {
  description = "Reviewed nonoverlapping IPv4 VPC range."
  type        = string
  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "Provide a valid IPv4 VPC CIDR."
  }
}

variable "private_subnet_cidrs" {
  description = "One reviewed node subnet per AZ; validate containment/overlap/IP budget at the site."
  type        = list(string)
  validation {
    condition     = length(var.private_subnet_cidrs) == length(var.availability_zones) && alltrue([for cidr in var.private_subnet_cidrs : can(cidrnetmask(cidr))])
    error_message = "Provide one valid node subnet per AZ."
  }
}

variable "public_subnet_cidrs" {
  description = "NAT public subnets per AZ, or empty for endpoint-only egress."
  type        = list(string)
  validation {
    condition     = (var.egress_mode == "endpoints" ? length(var.public_subnet_cidrs) == 0 : length(var.public_subnet_cidrs) == length(var.availability_zones)) && alltrue([for cidr in var.public_subnet_cidrs : can(cidrnetmask(cidr))])
    error_message = "Provide public NAT subnets per AZ or an empty list for endpoints."
  }
}

variable "service_ipv4_cidr" {
  description = "Reviewed Kubernetes service range without site/VPC overlap."
  type        = string
  validation {
    condition     = can(cidrnetmask(var.service_ipv4_cidr))
    error_message = "Provide an explicit IPv4 service CIDR."
  }
}

variable "egress_mode" {
  description = "Explicit connectivity and cost choice."
  type        = string
  validation {
    condition     = contains(["nat-single", "nat-per-az", "endpoints"], var.egress_mode)
    error_message = "Choose nat-single, nat-per-az or endpoints."
  }
}

variable "api_public_access_cidrs" {
  description = "Optional public API operator ranges; empty requires VPC-reachable administration."
  type        = list(string)
  validation {
    condition     = alltrue([for cidr in var.api_public_access_cidrs : can(cidrnetmask(cidr)) && try(cidrnetmask(cidr) != "0.0.0.0", false)])
    error_message = "Declare restricted operator CIDRs; unrestricted public access is unsupported."
  }
}

variable "node_capacity" {
  description = "On-Demand envelope; desired is initial only because upstream ignores later desired-size drift."
  type        = object({ min = number, desired = number, max = number })
  validation {
    condition     = var.node_capacity.min >= 1 && var.node_capacity.desired >= var.node_capacity.min && var.node_capacity.max >= var.node_capacity.desired && alltrue([for value in [var.node_capacity.min, var.node_capacity.desired, var.node_capacity.max] : floor(value) == value])
    error_message = "Declare integer 1 <= min <= initial desired <= max."
  }
}

variable "node_profile" {
  description = "Explicit pinned x86_64 AL2023 CPU AMI/instance cohort; GPU/ARM require separate qualification."
  type        = object({ architecture = string, ami_type = string, ami_release_version = string, instance_types = list(string), root_volume_gib = number })
  validation {
    condition     = var.node_profile.architecture == "x86_64" && var.node_profile.ami_type == "AL2023_x86_64_STANDARD" && startswith(var.node_profile.ami_release_version, "${var.kubernetes_version}.") && can(regex("^1[.][0-9]+[.][0-9]+-[0-9]{8}$", var.node_profile.ami_release_version)) && length(var.node_profile.instance_types) > 0 && alltrue([for instance in var.node_profile.instance_types : can(regex("^[a-z][a-z0-9-]+[.][a-z0-9]+$", instance)) && !can(regex("^(g|p|inf|trn|dl)[0-9]", instance))]) && var.node_profile.root_volume_gib >= 20 && floor(var.node_profile.root_volume_gib) == var.node_profile.root_volume_gib
    error_message = "Declare a matching pinned x86_64 CPU AMI, nonaccelerator instances and integer root disk >=20 GiB; actual instance/AMI compatibility remains an acceptance gate."
  }
}

variable "addon_versions" {
  description = "Exact approved build versions for the five required add-ons."
  type        = map(string)
  validation {
    condition     = toset(keys(var.addon_versions)) == toset(["vpc-cni", "kube-proxy", "coredns", "eks-pod-identity-agent", "aws-ebs-csi-driver"]) && alltrue([for version in values(var.addon_versions) : can(regex("^v[0-9]+[.][0-9]+[.][0-9]+-eksbuild[.][0-9]+$", version))])
    error_message = "Pin all five add-ons to explicit EKS build versions; verify compatibility on AWS."
  }
}

variable "control_plane_log_retention_days" {
  description = "Explicit control-plane log retention and storage/ingestion cost."
  type        = number
  validation {
    condition     = contains([7, 14, 30, 60, 90, 180, 365], var.control_plane_log_retention_days)
    error_message = "Choose supported 7/14/30/60/90/180/365 day retention."
  }
}

variable "state_bucket_name" {
  description = "Bootstrap-owned state bucket; used only to prohibit evidence co-location."
  type        = string
}

variable "evidence_bucket_name" {
  description = "Globally unique evidence-only bucket."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.evidence_bucket_name)) && var.evidence_bucket_name != var.state_bucket_name
    error_message = "Provide a valid bucket distinct from state."
  }
}

variable "evidence_key_prefix" {
  description = "Approved retained prefix configured consistently in the existing sink."
  type        = string
  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]+(/[a-zA-Z0-9_-]+)*/$", var.evidence_key_prefix)) && !strcontains(var.evidence_key_prefix, "..") && !startswith(var.evidence_key_prefix, "/")
    error_message = "Provide a nontraversing relative prefix ending in /."
  }
}

variable "evidence_retention_days" {
  description = "Explicit minimum lifecycle retention; not Object Lock or permanent immutability."
  type        = number
  validation {
    condition     = var.evidence_retention_days >= 1 && var.evidence_retention_days <= 3650 && floor(var.evidence_retention_days) == var.evidence_retention_days
    error_message = "Declare integer retention 1–3650 days satisfying the product promise."
  }
}

variable "product_namespace" {
  description = "Product namespace later created by Helm."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.product_namespace))
    error_message = "Use a Kubernetes DNS label namespace."
  }
}

variable "evidence_service_account" {
  description = "Product service account later created by Helm."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.evidence_service_account))
    error_message = "Use a Kubernetes DNS label service account."
  }
}

variable "ecr_repository_names" {
  description = "Explicit image repositories; no unverified image expiration is installed."
  type        = set(string)
  validation {
    condition     = length(var.ecr_repository_names) > 0 && alltrue([for name in var.ecr_repository_names : can(regex("^[a-z][a-z0-9/_-]+$", name))])
    error_message = "Declare product image repository names."
  }
}

variable "tags" {
  description = "Required billing and ownership tags."
  type        = map(string)
  validation {
    condition     = alltrue([for key in ["Product", "Environment", "Owner", "CostCenter"] : try(length(trimspace(var.tags[key])) > 0, false)])
    error_message = "Provide nonempty Product, Environment, Owner and CostCenter tags."
  }
}
