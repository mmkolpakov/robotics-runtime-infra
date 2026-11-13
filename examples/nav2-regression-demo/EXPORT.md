# Export and independently verify a Nav2 qualification

This path assesses the retained NavigateToPose recording, signs one selected
assessment with your own key, and exports its complete qualification inventory.
The recipient verifies the package using a public key received independently.
No private key, operator profile, or trusted public key is distributed in the
package.

The default case is `baseline` (passed). Use `--case criterion-sensitivity`,
`--case insufficient-observation`, or `--case missing-coverage` to export the
failed or incomplete verdict unchanged. The five cases have different run IDs
and scenarios, so each export contains one case, not a combined qualification.
The `evidence-refusal` control has no admissible result and cannot be exported.

## Prepare the tools and your trust directory

Use Linux, Bash, Python 3.12, uv or pip, jq, and Cosign **3.1.3 or newer**.
Install Cosign from a source you trust and check its release checksum before
using it. The setup below installs the published contracts **0.22.0** and harness
**0.23.1** from the hash-pinned
[Nav2 lock](../nav2-turtlebot3/requirements.lock), then builds the evaluator.

From this directory:

```bash
./run-demo.sh --prepare-only --skip-release-env
export DEMO_DIR="$PWD"
export REPO_DIR="$(cd ../.. && pwd)"
export TRUST_DIR="$HOME/.config/robotics-nav2-trial"
mkdir -p "$TRUST_DIR"
chmod 700 "$TRUST_DIR"
cosign version --json
cosign generate-key-pair --output-key-prefix "$TRUST_DIR/publisher"
```

Choose a private-key password when prompted. Keep `publisher.key` private.
For noninteractive signing, set `COSIGN_PASSWORD` through your usual secret
mechanism; do not commit it or put it in an evidence file.

Send `publisher.pub` to the recipient through an authenticated channel separate
from the qualification package. Compare its SHA-256 fingerprint through that
channel:

```bash
sha256sum "$TRUST_DIR/publisher.pub"
```

The operator directory must be outside the evidence work directory and export
directory. The public key is snapshotted there and SHA-256-pinned in the profile;
the publisher policy must name that same key. The profile also pins the Cosign
binary and offline trusted-root file. Neither a bundle's embedded key nor the
smoke test's generated key establishes trust.

## Bootstrap, assess, sign, and export

```bash
./run-export.sh --bootstrap \
  --operator-profile "$TRUST_DIR/nav2/operator-profile.json" \
  --publisher-key "$TRUST_DIR/publisher.key" \
  --public-key "$TRUST_DIR/publisher.pub" \
  --output "$DEMO_DIR/work/qualification-baseline"
```

For this first invocation, `$TRUST_DIR/nav2` must not exist. Bootstrap signs the
built evaluator wheel with your key and creates a read-only operator profile.
The existing SDK admission checks then authenticate that wheel and verify the
installed files before evaluation.

The export command:

1. Runs all five custody controls under your external operator profile.
2. Calls `robotics-acceptance aggregate` for the selected result.
3. Calls `scripts/qualification/create-statement` with the scenario, runtime,
   run context, result, aggregate, evidence index, original observation and
   evidence bytes, assessment configuration/environment, evaluator receipt and
   all its dependencies, JUnit, and extension schema.
4. Signs that exact statement with `cosign attest-blob --statement`.
5. Calls `scripts/qualification/package-artifacts`, adds the statement and
   signature, and calls `scripts/qualification/verify-bundle` with a pinned
   snapshot of your operator public key before publishing the output directory.

The native-files recording has no MCAP recording summary; none is fabricated.
The inventory includes the retained CDR, workload, cleanup, configuration, and
native observation instead.

The output directory must be new and inside the checkout, separate from the
evidence work directory. It contains `qualification-statement.json`,
`qualification.sigstore.json`, `qualification-arguments.txt`, extension
schemas, and the exact subject bytes under `subjects/`. Treat the entire
directory as the deliverable. Absolute producer URIs remain in signed documents;
verification resolves their digests against the packaged inventory, so the
package can move without editing signed bytes.

For later exports, reuse the same approved profile and omit `--bootstrap` and
`--public-key`:

```bash
./run-export.sh \
  --operator-profile "$TRUST_DIR/nav2/operator-profile.json" \
  --publisher-key "$TRUST_DIR/publisher.key" \
  --case criterion-sensitivity \
  --output "$DEMO_DIR/work/qualification-sensitivity"
```

An existing profile must approve the currently installed evaluator wheel. If
that wheel or the approved Cosign binary changes, review the new bytes and
bootstrap a new operator directory explicitly. To reproduce only the demo with
this trust configuration, run
`./run-demo.sh --operator-profile "$TRUST_DIR/nav2/operator-profile.json"`.

## Independently verify the delivered package

The recipient needs the same published contracts cohort, jq, Bash, and an
independently installed Cosign 3.1.3+. The recipient does not need your private
key, profile, original work directory, or evaluator installation to verify the
qualification signature and inventory.

Install the hash-pinned tools from a trusted checkout:

```bash
python3.12 -m venv verifier-venv
verifier-venv/bin/python -m pip install --require-hashes --only-binary=:all: \
  -r /path/to/robotics-runtime-infra/examples/nav2-turtlebot3/requirements.lock
export ROBOTICS_CONTRACTS_CLI="$PWD/verifier-venv/bin/robotics-contracts"
```

Set `VERIFY_SCRIPT` from that trusted checkout. Set `EXPECTED_KEY` to the
public key obtained out-of-band, after comparing its fingerprint. Do not select
a key supplied inside the package.

```bash
export VERIFY_SCRIPT=/path/to/robotics-runtime-infra/scripts/qualification/verify-bundle
export EXPECTED_KEY=/path/to/independently-received/publisher.pub
cd /path/to/delivered/qualification-baseline
mapfile -t inventory < qualification-arguments.txt
"$VERIFY_SCRIPT" "${inventory[@]}" \
  --bundle qualification.sigstore.json --key "$EXPECTED_KEY"
```

Success prints `qualification bundle verified for run-... as key-sha256:...`
and exits zero. A wrong key or changed evidence byte must exit nonzero.
Verification establishes the signature, exact bytes, and contract consistency;
inspect `subjects/acceptance-aggregate.json` for the qualification verdict.
An authentic failed or incomplete assessment remains failed or incomplete.

## Scope and validation

This is a new assessment of an existing recorded capture, not new robot
execution. The runtime and run context are reconstructed with logical timestamps
from the recorded start; assessment and signing happen now. The signature does
not establish that these reconstructed inputs existed before the original run.

The native wheel evaluator runs in-process with admission and RECORD-hash
guards. It has no resource, filesystem, or network sandbox. The OCI executor is
the contained evaluation path. Key-only signing does not establish OIDC
identity, transparency time, or build provenance.

The source-foundation lock remains contracts 0.21.1 / harness 0.22.2; this
published-example path intentionally uses contracts 0.22.0 / harness 0.23.1.

Run the automated controls with Cosign on PATH (or
`ROBOTICS_COSIGN_PROFILE` set to your pinned tool profile):

```bash
.venv/bin/python -m unittest test_demo test_export -v
```

The export tests generate fresh temporary keypairs, verify the complete package,
move it and make the original evidence unavailable, and reject a wrong key, one
changed evidence byte, and a foreign operator profile. Temporary test keys and
artifacts are cleaned up.
