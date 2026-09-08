# Host time fixtures

`scripts/ci/integration/verify-host-time-evidence.sh` exercises the host sampler,
Collector and installed acceptance harness together. Its positive Chrony case
runs a client against a separate synthetic NTP source on a private Docker
network. The source listens on UDP 1123 inside that network; no port is published.
The client shares the source's network namespace and polls over loopback at
1/16 second. This short interval is confined to the synthetic local source.
Both daemons use `-x` and drop all capabilities, so they cannot adjust the host
clock. This proves the evidence path, not the accuracy of a lab time authority.

The client waits for synchronization before sampling. Its reference time comes
from actual NTP measurements; the local-reference server's tracking record is
never used as client evidence. Chrony deliberately dates local-reference records
at least one second earlier, which cannot satisfy the one-second freshness limit.
See the [Chrony 4.5 implementation](https://github.com/mlichvar/chrony/blob/4.5/reference.c).

The negative Chrony case has no configured source. PTP fixtures separately cover
synchronized, unsynchronized and stale observations. Failed runs retain raw
samples, tracking CSV, daemon and Collector logs in `artifacts/host-time/`.
