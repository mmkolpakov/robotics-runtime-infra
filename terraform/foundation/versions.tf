terraform {
  required_version = "= 1.16.5"
  required_providers {
    aws       = { source = "hashicorp/aws", version = "= 6.67.0" }
    time      = { source = "hashicorp/time", version = "= 0.14.2" }
    tls       = { source = "hashicorp/tls", version = "= 4.4.1" }
    cloudinit = { source = "hashicorp/cloudinit", version = "= 2.4.1" }
    null      = { source = "hashicorp/null", version = "= 3.3.2" }
  }
}
provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]
  default_tags { tags = var.tags }
}
