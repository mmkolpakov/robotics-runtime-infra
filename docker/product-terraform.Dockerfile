# syntax=docker/dockerfile:1.19
FROM hashicorp/terraform:1.16.5@sha256:c7926feace05d0f7e73542842bf3945924e955a1f782cf000ccbb8d18fa42d77
ENV TF_IN_AUTOMATION=1 CHECKPOINT_DISABLE=1 AWS_EC2_METADATA_DISABLED=true
COPY terraform/ /src/terraform/
RUN set -eu; export TF_PLUGIN_CACHE_DIR=/tmp/provider-cache; mkdir -p "$TF_PLUGIN_CACHE_DIR"; for root in state-bootstrap foundation; do \
      cd "/src/terraform/$root" && terraform init -backend=false -input=false -lockfile=readonly; \
    done
COPY scripts/ci/check-product-terraform.sh /usr/local/bin/check-product-terraform
ENTRYPOINT ["/bin/sh", "/usr/local/bin/check-product-terraform", "--inside-container"]
