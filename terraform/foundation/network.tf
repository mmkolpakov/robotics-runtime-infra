module "vpc" {
  source                 = "terraform-aws-modules/vpc/aws"
  version                = "6.7.3"
  name                   = var.cluster_name
  cidr                   = var.vpc_cidr
  azs                    = var.availability_zones
  private_subnets        = var.private_subnet_cidrs
  public_subnets         = var.public_subnet_cidrs
  enable_dns_hostnames   = true
  enable_dns_support     = true
  create_igw             = var.egress_mode != "endpoints"
  enable_nat_gateway     = var.egress_mode != "endpoints"
  single_nat_gateway     = var.egress_mode == "nat-single"
  one_nat_gateway_per_az = var.egress_mode == "nat-per-az"
  private_subnet_tags    = { "kubernetes.io/role/internal-elb" = "1" }
  tags                   = var.tags
}
module "endpoints" {
  source                = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version               = "6.7.3"
  region                = var.aws_region
  vpc_id                = module.vpc.vpc_id
  subnet_ids            = module.vpc.private_subnets
  create_security_group = var.egress_mode == "endpoints"
  security_group_name   = "${var.cluster_name}-endpoints"
  security_group_rules = {
    private_https = {
      description = "HTTPS from declared private node subnets"
      cidr_blocks = var.private_subnet_cidrs
    }
  }
  endpoints = merge({
    s3 = {
      service_endpoint = "com.amazonaws.${var.aws_region}.s3"
      service_type     = "Gateway"
      route_table_ids  = module.vpc.private_route_table_ids
    }
    }, var.egress_mode == "endpoints" ? {
    for service in ["ec2", "ecr.api", "ecr.dkr", "eks-auth", "sts", "logs"] : service => {
      service_endpoint    = "com.amazonaws.${var.aws_region}.${service}"
      private_dns_enabled = true
    }
  } : {})
  tags = var.tags
}
