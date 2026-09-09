# Evidence producers

The evidence image installs contracts from the pinned workspace wheel, alongside
the `mcap` extra exported from the same `uv.lock`. `mcap-summary SOURCE OUTPUT`
is a compatibility entrypoint for
`robotics-contracts recording-summary from-mcap SOURCE --output OUTPUT`.
Its output is `recording-summary.v1`; the entrypoint name does not identify a
legacy schema. Extraction, footer checks, validation and serialization belong
to contracts. The shell wrapper publishes a read-only file atomically and
preserves any previous output when extraction fails.

The collector writes OTLP records to `/evidence/metrics.otlp.jsonl`.
Observer arguments, artifact registration and qualification inputs use that
same path. The artifact media type is `application/x-ndjson`.

The producer and observer mount the recording directory at
`/evidence/recordings`. Local artifacts and provenance inputs must remain beneath
the index directory, `/evidence`, with the same paths in both containers.

Artifact registrations are internal state under `/evidence/state/registrations`;
they are not public receipts. They bind the run ID, source path and observed byte
digest. Index finalization uses the contracts `evidence-index init`, `add-artifact`
and `finalize` commands. Sources and recording summaries must remain available
and unchanged until finalization. Failed validation preserves the previous
index. Index output cannot replace an evidence source, summary or receipt.

Local artifacts need no receipt. An uploaded artifact requires an
`artifact-receipt.v1` tied to its exact URI, byte digest, size, media type,
immutable object version and run. Registration rejects S3's mutable `null`
version and records object keys as
percent-encoded URIs, including spaces and reserved URI characters.

The evidence image includes `retained-artifact` and the documented
[Cosign dependency rebuild](../docker/cosign/README.md).
Prepare a retention predicate from a confirmed registration and the
original recording:

```sh
source=/evidence/recordings/recording_0.mcap
digest=$(sha256sum "$source" | cut -d' ' -f1)
registration="/evidence/state/registrations/0-${digest}.json"
retained-artifact predicate --registration "$registration" --source "$source" \
  > /evidence/retention-predicate.json
cosign attest-blob --yes --key /run/secrets/evidence.key \
  --predicate /evidence/retention-predicate.json \
  --type https://robotics-runtime.dev/attestations/artifact-retention/v1 \
  --bundle /evidence/retention.sigstore.json "$source"
```

Run signing where the producer's private key is available. Supply the public
verification key independently through the verifier's trust configuration.
The verifier snapshots the registration, bundle and public key, downloads the
exact S3 `VersionId`, checks the full response range, size, media type and SHA-256,
and asks Cosign to verify the signature and recording digest. It also checks
that the authenticated predicate names this URI, version and run:

```sh
retained-artifact verify --registration "$registration" \
  --bundle /evidence/retention.sigstore.json --key /run/trust/evidence.pub \
  --output /evidence/provenance/recording-0
```

The public key is the trust anchor in this mode; its original PEM bytes are
retained as `trust-policy.pem`. Verification identifies it by byte SHA-256 and
does not claim a Fulcio identity or transparency-log inclusion. No key supplied
inside a bundle becomes trusted. Both in-toto Statement v0.1 (emitted by Cosign
3.1.3 `attest-blob`) and v1 are supported for this retention predicate; the
authenticated payload bytes are preserved unchanged.

AWS credentials, region and `AWS_ENDPOINT_URL` use the normal AWS CLI environment.
The caller needs permission to read the selected object version. The default
download limit is 1 GiB, configurable with `--max-artifact-bytes`; temporary
readback bytes use the output filesystem and are removed after verification.
The output directory must be new. It is published only after all checks pass.
It contains `artifact-verification.v1`, the raw signed statement, public key,
Sigstore bundle and the S3 response metadata. Create the receipt with the exact
three provenance dependencies:

```sh
evidence-sink receipt /evidence/recordings/recording_0.mcap 0 \
  --verification /evidence/provenance/recording-0/artifact-verification.json \
  --dependency /evidence/provenance/recording-0/statement.json \
  --dependency /evidence/provenance/recording-0/trust-policy.pem \
  --dependency /evidence/provenance/recording-0/verification-evidence.sigstore.json
evidence-sink finalize
```

The upload must already have a confirmed registration. This command delegates
receipt construction to contracts and checks that its descriptor matches the
registered upload. It does not perform signature verification. Preserve the
verification record and dependencies beneath `/evidence` for the harness's
receipt inputs. An S3 upload checksum alone does not supply an external
provenance verification.

Receipt registration remembers these input paths. Finalization rechecks their
bytes and publishes `receipt-inventory.json` before the final index. The inventory
lists canonical relative paths in `receipts`, `verifications` and `dependencies`;
shared dependency bytes appear once. The observer supplies `--receipt-inventory`
and loads it when evidence becomes available after measurement. Local-only runs
publish empty lists. Missing, changed or unreferenced provenance prevents
publication and leaves the previous index and inventory intact.

`EVIDENCE_DELETE_CONFIRMED_LOCAL=true` removes only confirmed remote sources
after the index has been validated and published. It requires a writable spool
mount; the default Compose mount is read-only. Re-finalization after deletion
requires restoring the original files, since the public writer rechecks bytes.
With only local artifacts, merely selecting S3 mode reports no remote upload.

`test/ci/test_retained_artifact.py` uses real Cosign signatures and explicitly
simulated S3 responses to test byte, run, version, key and range mismatches.
The live S3 verifier/consumer handoff remains a separate integration gate.
`scripts/ci/integration/verify-versioned-s3-evidence.sh` runs that gate against
the versioned SeaweedFS fixture. It rejects a foreign key and changed remote
bytes, verifies the original version after an overwrite, then loads the final
index and inventory with the installed harness in an offline container. It runs
in both foundation integration and CPU integration; generated private test keys
remain in container tmpfs and are never uploaded with the evidence.
