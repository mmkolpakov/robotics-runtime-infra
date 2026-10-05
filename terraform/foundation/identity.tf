locals {
  cluster_arn = "arn:aws:eks:${var.aws_region}:${var.aws_account_id}:cluster/${var.cluster_name}"
  pod_identities = {
    csi      = { namespace = "kube-system", service_account = "ebs-csi-controller-sa" }
    evidence = { namespace = var.product_namespace, service_account = var.evidence_service_account }
  }
  evidence_arn         = "arn:aws:s3:::${var.evidence_bucket_name}"
  evidence_objects_arn = "${local.evidence_arn}/${var.evidence_key_prefix}*"
}
resource "aws_iam_role" "pod_identity" {
  for_each = local.pod_identities
  name     = "${var.cluster_name}-${each.key}"
  path     = "/"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = { StringEquals = {
        "aws:RequestTag/eks-cluster-arn"            = local.cluster_arn
        "aws:RequestTag/kubernetes-namespace"       = each.value.namespace
        "aws:RequestTag/kubernetes-service-account" = each.value.service_account
      } }
    }]
  })
}
resource "aws_iam_role_policy_attachment" "csi" {
  role       = aws_iam_role.pod_identity["csi"].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEBSCSIDriverPolicyV2"
}
resource "aws_iam_role_policy" "evidence" {
  name = "retained-evidence"
  role = aws_iam_role.pod_identity["evidence"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ObserveProvisionedBucket", Effect = "Allow"
        Action = ["s3:GetBucketVersioning", "s3:GetBucketLocation"], Resource = local.evidence_arn
      },
      {
        Sid       = "ListRetainedPrefix", Effect = "Allow"
        Action    = ["s3:ListBucket"], Resource = local.evidence_arn
        Condition = { StringLike = { "s3:prefix" = ["${var.evidence_key_prefix}*"] } }
      },
      {
        Sid      = "RetainAndVerifyExactVersions", Effect = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:GetObjectVersion", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
        Resource = local.evidence_objects_arn
      },
      {
        Sid    = "UploaderCannotDeleteRetainedBytes", Effect = "Deny"
        Action = ["s3:DeleteObject", "s3:DeleteObjectVersion"], Resource = "${local.evidence_arn}/*"
      }
    ]
  })
}
resource "aws_eks_pod_identity_association" "evidence" {
  cluster_name         = module.eks.cluster_name
  namespace            = var.product_namespace
  service_account      = var.evidence_service_account
  role_arn             = aws_iam_role.pod_identity["evidence"].arn
  disable_session_tags = false
  depends_on           = [aws_iam_role_policy.evidence]
}
