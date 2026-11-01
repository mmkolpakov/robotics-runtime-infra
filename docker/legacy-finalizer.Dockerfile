# syntax=docker/dockerfile:1.14
ARG COORDINATOR_IMAGE
ARG COSIGN_IMAGE
# Publisher image is the existing repository COSIGN_IMAGE lock.
# hadolint ignore=DL3026
FROM ${COSIGN_IMAGE} AS cosign
FROM ${COORDINATOR_IMAGE}
ARG COSIGN_VERSION
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
USER 0:0
COPY --from=cosign /usr/bin/cosign /usr/local/bin/cosign
# License context uses the version selected by Bake; the binary stays publisher pinned.
# hadolint ignore=DL3022
COPY --from=cosign-license /LICENSE /usr/share/licenses/cosign/LICENSE
COPY scripts/qualification /opt/robotics/finalizer/scripts/qualification
COPY scripts/ci/foundation/sign-ephemeral-qualification.sh /opt/robotics/finalizer/scripts/ci/foundation/sign-ephemeral-qualification.sh
COPY host/workers/legacy-finalization /opt/robotics/finalizer/workers
ENV PATH="/opt/contracts/bin:/usr/local/bin:/usr/bin:/bin" \
    HOME=/tmp/finalizer
RUN printf '%s  %s\n' c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4 /usr/share/licenses/cosign/LICENSE | sha256sum --check \
    && cosign version --json > /usr/share/robotics-runtime/finalizer-cosign-version.json \
    && jq -e --arg version "${COSIGN_VERSION}" '.gitVersion == ("v" + $version + "+dirty") and .gitCommit == "0e48502cf5ef34e2e60bbd3617aa19945712f705"' /usr/share/robotics-runtime/finalizer-cosign-version.json \
    && /opt/contracts/bin/python -c 'import json;from importlib.metadata import version;lock=json.load(open("/usr/share/robotics-runtime/foundation-lock.json"));assert all(version(p["distribution"])==p["version"] for p in lock["packages"].values())' \
    && chmod -R a-w /opt/robotics/finalizer \
    && chmod 0555 /opt/robotics/finalizer/scripts/qualification/package-artifacts \
       /opt/robotics/finalizer/scripts/qualification/create-statement \
       /opt/robotics/finalizer/scripts/qualification/verify-bundle \
    && sha256sum /usr/local/bin/cosign > /usr/share/robotics-runtime/finalizer-cosign.sha256
USER 1000:1000
WORKDIR /opt/robotics/finalizer
ENTRYPOINT []
