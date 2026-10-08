module "eks" {
  source                                   = "terraform-aws-modules/eks/aws"
  version                                  = "21.26.0"
  name                                     = var.cluster_name
  kubernetes_version                       = var.kubernetes_version
  upgrade_policy                           = { support_type = var.kubernetes_support_type }
  vpc_id                                   = module.vpc.vpc_id
  subnet_ids                               = module.vpc.private_subnets
  service_ipv4_cidr                        = var.service_ipv4_cidr
  endpoint_private_access                  = true
  endpoint_public_access                   = length(var.api_public_access_cidrs) > 0
  endpoint_public_access_cidrs             = var.api_public_access_cidrs
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = false
  enable_irsa                              = false
  create_kms_key                           = false
  encryption_config                        = null
  compute_config                           = { enabled = false }
  enabled_log_types                        = ["audit", "api", "authenticator"]
  cloudwatch_log_group_retention_in_days   = var.control_plane_log_retention_days
  iam_role_name                            = "${var.cluster_name}-cluster"
  iam_role_use_name_prefix                 = false
  access_entries = {
    for arn in var.cluster_admin_role_arns : arn => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }
  addons = {
    for name, version in var.addon_versions : name => {
      addon_version  = version
      most_recent    = false
      before_compute = contains(["vpc-cni", "eks-pod-identity-agent"], name)
      pod_identity_association = name == "aws-ebs-csi-driver" ? [{
        # Depend only on CSI policy attachment; keep identity data outside a module-wide depends_on.
        role_arn        = "arn:aws:iam::${var.aws_account_id}:role/${aws_iam_role_policy_attachment.csi.role}"
        service_account = "ebs-csi-controller-sa"
      }] : null
    }
  }
  eks_managed_node_groups = {
    general = {
      name                           = "${var.cluster_name}-general"
      use_name_prefix                = false
      min_size                       = var.node_capacity.min
      desired_size                   = var.node_capacity.desired
      max_size                       = var.node_capacity.max
      capacity_type                  = "ON_DEMAND"
      ami_type                       = var.node_profile.ami_type
      ami_release_version            = var.node_profile.ami_release_version
      use_latest_ami_release_version = false
      instance_types                 = var.node_profile.instance_types
      iam_role_name                  = "${var.cluster_name}-general"
      iam_role_use_name_prefix       = false
      iam_role_attach_cni_policy     = true
      use_custom_launch_template     = true
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }
      block_device_mappings = {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.node_profile.root_volume_gib
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
    }
  }
  tags = var.tags
}
