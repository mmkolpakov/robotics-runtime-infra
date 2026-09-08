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

During the workspace migration, the index/receipt and qualification wrappers
still require conversion to the v1 public roles. A successful recording-summary
test alone does not qualify the entire local or S3 evidence pipeline. Remote
evidence requires a typed receipt bound to external provenance verification;
an S3 upload checksum is not such a receipt.
