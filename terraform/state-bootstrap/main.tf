locals {
  state_arns = [for key in var.state_keys : "arn:aws:s3:::${var.state_bucket_name}/${key}"]
  lock_arns  = [for key in var.state_keys : "arn:aws:s3:::${var.state_bucket_name}/${key}.tflock"]
}
resource "aws_s3_bucket" "state" {
  bucket        = var.state_bucket_name
  force_destroy = false
  lifecycle { prevent_destroy = true }
}
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}
resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "RequireTLS", Effect = "Deny", Principal = "*", Action = ["s3:*"]
        Resource  = ["arn:aws:s3:::${var.state_bucket_name}", "arn:aws:s3:::${var.state_bucket_name}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid    = "ListApprovedState", Effect = "Allow", Principal = { AWS = sort(tolist(var.state_operator_role_arns)) }
        Action = ["s3:ListBucket"], Resource = ["arn:aws:s3:::${var.state_bucket_name}"]
      },
      {
        Sid    = "ReadWriteApprovedState", Effect = "Allow", Principal = { AWS = sort(tolist(var.state_operator_role_arns)) }
        Action = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"], Resource = local.state_arns
      },
      {
        Sid    = "ManageOnlyLockfiles", Effect = "Allow", Principal = { AWS = sort(tolist(var.state_operator_role_arns)) }
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = local.lock_arns
      },
      {
        Sid    = "ProtectStateHistory", Effect = "Deny", Principal = { AWS = sort(tolist(var.state_operator_role_arns)) }
        Action = ["s3:DeleteObject", "s3:DeleteObjectVersion"], Resource = local.state_arns
      }
    ]
  })
}
