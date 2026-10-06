# syntax=docker/dockerfile:1.14
# Source-only native cohort, using installed public workers and unchanged retention helpers.
FROM docker.io/rclone/rclone:1.75.1@sha256:45401ad7410db1d67ffdb58e19059ad20b0d8e0285a60e38bbec55cc1019c7a5 AS rclone
FROM docker.io/amazon/aws-cli:2.35.21@sha256:238583846e731f31c9848dae26c5a560769ff35c4c5368a4cb6be5816683e485 AS aws
FROM ghcr.io/astral-sh/uv:0.11.28@sha256:0f36cb9361a3346885ca3677e3767016687b5a170c1a6b88465ec14aefec90aa AS uv
ARG EVIDENCE_BASE_IMAGE
FROM ${EVIDENCE_BASE_IMAGE}
USER 0:0
COPY --from=uv /uv /usr/local/bin/uv
COPY docker/python/evidence-sink.lock /tmp/evidence-sink.lock
COPY --from=rclone /usr/local/bin/rclone /usr/local/bin/rclone
COPY --from=aws /usr/local/aws-cli /usr/local/aws-cli
ADD https://raw.githubusercontent.com/rclone/rclone/687d264b689b8c49a67e2e52a8a5e0caa01c04ce/COPYING /usr/share/licenses/rclone/COPYING
ADD https://github.com/foxglove/mcap/releases/download/releases%2Fmcap-cli%2Fv0.3.0/mcap-linux-amd64 /usr/local/bin/mcap
RUN printf '%s\n' '8cd2e9e750b90a04b7d82dbbca3930c696ae0309d7c10464f90a44f45754cd04  /usr/share/licenses/rclone/COPYING' '5d4100573fab880f1c6400952466275bb3b32c3d230a54f7c380ee0d08e59eef  /usr/local/bin/mcap' | sha256sum --check \
    && chmod 0555 /usr/local/bin/mcap \
    && ln -s /usr/local/aws-cli/v2/current/bin/aws /usr/local/bin/aws \
    && apt-get update \
    && apt-get install -y --no-install-recommends jq inotify-tools passwd \
    && /usr/local/bin/uv pip install --python /opt/contracts/bin/python --require-hashes --no-deps -r /tmp/evidence-sink.lock \
    && /usr/local/bin/uv pip check --python /opt/contracts/bin/python \
    && /opt/contracts/bin/python -c 'import json;from importlib.metadata import version;lock=json.load(open("/usr/share/robotics-runtime/foundation-lock.json"));assert all(version(p["distribution"])==p["version"] for p in lock["packages"].values());from robotics_runtime_contracts.recordings import recording_summary_from_mcap;from mcap.reader import make_reader' \
    && cosign version --json \
    && test "$(cosign version --json | jq -r '.gitVersion | ltrimstr("v") | split("+")[0]')" = '3.1.3' \
    && /usr/local/bin/uv pip freeze --python /opt/contracts/bin/python > /usr/share/robotics-runtime/evidence-python-packages.txt \
    && dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\n' | sort > /usr/share/robotics-runtime/evidence-deb-packages.tsv \
    && /usr/sbin/groupadd --gid 10001 evidence \
    && /usr/sbin/useradd --uid 10001 --gid 10001 --create-home evidence \
    && rm -rf /var/lib/apt/lists/* /tmp/evidence-sink.lock
COPY --chmod=0555 docker/evidence-sink/evidence-sink /usr/local/bin/evidence-sink
COPY --chmod=0555 docker/evidence-sink/mcap-summary /usr/local/bin/mcap-summary
COPY --chmod=0555 docker/evidence-sink/retained-artifact.py /usr/local/bin/retained-artifact
COPY --chmod=0555 docker/evidence-sink/receipt-inputs.py /usr/local/bin/receipt-inputs
ENV PATH="/opt/contracts/bin:${PATH}" HOME=/home/evidence PYTHONDONTWRITEBYTECODE=1
USER 10001:10001
ENTRYPOINT ["/usr/local/bin/evidence-sink"]
CMD ["watch"]
