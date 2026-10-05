output "state_backend" {
  description = "Nonsecret backend coordinates; each root selects its own approved key."
  value = {
    bucket       = var.state_bucket_name
    region       = var.aws_region
    encrypt      = true
    use_lockfile = true
    allowed_keys = var.state_keys
  }
}
