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

Artifact registrations are internal state under `/evidence/state/registrations`;
they are not public receipts. They bind the run ID, source path and observed byte
digest. Index finalization uses the contracts `evidence-index init`, `add-artifact`
and `finalize` commands. Sources and recording summaries must remain available
and unchanged until finalization. Failed validation preserves the previous
index. Index output cannot replace an evidence source, summary or receipt.

Local artifacts need no receipt. An uploaded artifact requires an
`artifact-receipt.v1` tied to its exact URI, byte digest, size, media type,
immutable object version and run. After the external provenance verifier has
produced a passing verification record and retained its dependencies, create it:

```sh
evidence-sink receipt /spool/recording_0.mcap 0 \
  --verification /evidence/provenance/verification.json \
  --dependency /evidence/provenance/statement.json \
  --dependency /evidence/provenance/trust-policy.json \
  --dependency /evidence/provenance/verification-evidence.json
evidence-sink finalize
```

The upload must already have a confirmed registration. This command delegates
receipt construction to contracts and checks that its descriptor matches the
registered upload. It does not perform signature verification. Preserve the
verification record and dependencies for the harness's receipt inputs. An S3
upload checksum alone does not supply an external provenance verification.

`EVIDENCE_DELETE_CONFIRMED_LOCAL=true` removes only confirmed remote sources
after the index has been validated and published. It requires a writable spool
mount; the default Compose mount is read-only. Re-finalization after deletion
requires restoring the original files, since the public writer rechecks bytes.
With only local artifacts, merely selecting S3 mode reports no remote upload.

Qualification wrappers and the complete external S3 verifier/consumer handoff
are still being migrated on the integration branch. The local producer tests
do not establish live S3, signature, or end-to-end qualification.
