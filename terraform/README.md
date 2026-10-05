# Product AWS foundation

This candidate provides Terraform configuration and offline configuration checks.
No AWS backend has been initialized and no AWS API, plan against a real account,
apply, resource creation or acceptance test has been performed.

Ownership is deliberately small: Terraform owns the AWS network, EKS/EC2 managed
capacity, ECR, IAM/Pod Identity, required add-ons and S3 storage. Later product
Helm owns Kubernetes service accounts, workloads, PVC/StorageClass policy and
run packaging. Product Ansible independently owns enrolled physical product
nodes. No developer-workstation paths, inventory, roles or services are reused.
The foundation does not supply a scheduler, operator, database or platform SDK.

## Published pins

Verified from primary publisher endpoints on 5 October 2026:

- [Terraform 1.16.5](https://releases.hashicorp.com/terraform/1.16.5/); the
  project container pins the official multiarch image by digest.
- [hashicorp/aws 6.67.0](https://github.com/hashicorp/terraform-provider-aws/releases/tag/v6.67.0).
- [VPC 6.7.3](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/6.7.3)
  including its standard endpoints submodule.
- [EKS 21.26.0](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/21.26.0).
- Transitive provider pins: hashicorp/time 0.14.2, tls 4.4.1,
  cloudinit 2.4.1 and null 3.3.2. Each root commits its provider checksum lock.
  EKS's pinned source also pins its KMS dependency; this configuration disables
  creating that customer-managed key and disables IRSA. Standard EKS encryption
  and the explicitly encrypted S3/EBS settings still need real acceptance.

The example inputs are intentionally unusable deployment placeholders. The
mock tests instead use fictitious account/AMI/add-on values and certificates;
they are not a suggested or qualified deployment cohort.

## State bootstrap and environment inputs

`state-bootstrap` owns a separate versioned, AES256-encrypted, private state
bucket. Its initial backend is Terraform's local default. An independently
authorized operator must retain that protected bootstrap state, then add the
provided S3 backend example and migrate it only after the bucket exists. Both
the migrated bootstrap and foundation backends use `use_lockfile=true`;
there is no DynamoDB lock service. Keep different explicit state object keys.

`foundation` has a partial S3 backend; supply its reviewed bucket/key/region
configuration from the examples during approved deployment. The supplied
state_bucket_name must match the actual reviewed backend bucket; backend-disabled
checks cannot prove that correspondence. Actual acceptance checks the configured
backend and forbids using the evidence bucket for state. No credentials
belong in backend files, tfvars, plans, logs or Git. Use the normal external
credential chain. The provider checks the explicitly expected account on real
deployment. Existing approved operator/admin IAM roles are prerequisites.

State bucket permissions permit the declared operator roles to read/write only
approved state keys, fetch historical versions and delete the corresponding
`.tflock` objects. State objects/history remain protected from those delete
actions. Both buckets prohibit insecure transport and public access, and reject
Terraform bucket destruction. This protects this managed configuration, not
privileged account administrators or an independently changed configuration.

## Deployment choices and cost

All region, AZ/CIDR, service CIDR, cluster/version/support, operator role,
add-on build, node AMI/instance/cohort/capacity, bucket/prefix/retention and
billing-owner settings are explicit inputs. Subnet containment/overlap, pod IP
budget, node architecture/AMI compatibility, available EKS/add-on versions and
regional quotas require site/account verification.

Initial capacity is Linux x86_64 CPU EC2 managed nodes using an explicit AL2023
AMI release. Automatic latest AMI/add-on selection, Auto Mode, Spot, accelerated
and ARM node profiles are not enabled. GPU provider qualification requires a
separately reviewed supported AMI/driver/runtime/image/instance profile; an AMI
name does not establish provider compatibility. Upstream treats desired size as
initial only; min/max are the ongoing envelope. Autoscaling operations remain
with the standard capacity owner introduced by the deployment profile.

Choose `nat-single`, `nat-per-az`, or `endpoints` deliberately. A single NAT
has lower standing cost and an AZ availability/cross-AZ traffic tradeoff.
Per-AZ NAT costs more. Endpoint-only mode creates required AWS service interface
endpoints and an S3 gateway endpoint; it has no general internet route, so all
required product/add-on images and dependencies must be available through the
approved private routes/ECR. No external registry mirroring is performed here.
An empty public API CIDR list requires a VPC-reachable deployment/operator path.
The interface endpoints incur standing and traffic costs. No least-cost choice
is asserted without the workload/region measurements.

Explicit root disk sizes, bounded node counts, log retention, ECR image storage,
EKS control-plane/version-support costs, EBS, S3 versions/requests, egress/NAT/
endpoints and diagnostic/recovery effort belong in actual TCO comparison.
ECR tags are immutable; referenced image expiry is not guessed or automated.

## Evidence retention and acceptance boundary

The evidence bucket is separate from state. The declared retained prefix has
explicit current and noncurrent lifecycle retention. Set it to meet every
promised artifact retention interval. Do not shorten it while unexpired promises
or referenced versions remain. Lifecycle expiration is deliberately supported;
this is not Object Lock, permanent WORM storage or proof of immutable retention
against a privileged administrator.

The evidence workload role allows prefix-scoped upload and exact-version
retrieval, explicitly denies deletion of retained objects/versions, and is
bound to the declared cluster/namespace/service account using Pod Identity
request tags. Existing rclone/AWS CLI/Cosign/VersionId/SHA-256/size protocols and
signing trust remain outside these Terraform resources. The evidence_environment
output supplies the existing sink region/bucket/prefix variables, trims the IAM
prefix trailing slash, and disables rclone bucket creation/checking for the
already provisioned bucket. The role permits the sink's existing bucket-versioning
preflight; it does not grant bucket creation. Product Helm must retain these
standard settings and the existing named remote configuration.

CSI uses the maintained AWS
[AmazonEBSCSIDriverPolicyV2](https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AmazonEBSCSIDriverPolicyV2.html).
Its authoritative ARN has no `service-role/` component. The cluster-scoped
trust restricts who can assume the CSI role; the AWS managed volume policy is
tag-scoped within the account and is not proof of cross-cluster volume isolation.
Real IAM denial and storage isolation must be qualified before support.

Run `scripts/ci/check-product-terraform.sh` from the repository root. Docker is
the default CI engine; HOME uses the explicit
`ROBOTICS_IMAGE_ENGINE=podman scripts/ci/check-product-terraform.sh` selection.
Only docker/podman are accepted. The check command builds a pinned project
container, initializes modules/provider packages with
`init -backend=false -lockfile=readonly`, then runs fmt/validate and full-graph
plan tests with every provider mocked and networking disabled. No module graph
is replaced by an override. Mock IAM-policy-document data is fake; product IAM
JSON assertions inspect the product's own policy documents directly.

The maintainer `scripts/ci/lock-product-terraform.sh` helper regenerates provider
checksums with `init -backend=false`. It uses the same engine selection and caller
UID/GID for its lockfile bind mount (with keep-id for rootless Podman).

These are configuration checks, not AWS acceptance. Real acceptance must
establish backend migration/locking, apply/second-plan convergence, account/
IAM denial/credential behavior, image pulls, real node/AMI/add-on facts, CSI
encryption/recovery/isolation, exact S3 version retention/retrieval and signatures,
clean teardown and actual billed TCO. Retained run PVCs and recovery must remain
independent of Job lifetime in the later Helm/provider implementation.
