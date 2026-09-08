# linux-libc-dev applicability review — 2026-09-08

This document preserves the original 135-CVE review and NVIDIA-only v4 decision. The
[completed-image follow-up](linux-libc-dev-2026-09-08.images.md) records the subsequent arm64
evidence and active v5 scope.

Review prepared in `review/trivy-linux-libc-dev`, initially based on original infra commit
`d36ee2a`. The pin update was committed as `5245fae` and integrated by the parent as `a2f62d3`. This
VEX change follows the rebuilt amd64 residual in CI run `34192891669`; the scanner and severity gate
are unchanged.

## Finding and proposed resolution

The supplied NVIDIA report contains **135 new findings: 5 CRITICAL and 130 HIGH**, all attributed to
`linux-libc-dev=6.8.0-136.136`. None overlaps the 55 existing OpenVEX v3 statements. Ubuntu's
current `linux`/`noble` rows independently confirm six fixes at `6.8.0-139.139` and 129
vulnerable/work-in-progress statuses for the kernel source package. These statuses do not establish
applicability to every binary built from that source package.

Input report: `analysis/ci-artifacts/nvidia/nvidia-inference-nvidia-local.json`; SHA256
`ffcfc4b990fb7638f54f51693b2f402bbf61246621b7115e30c24dffd6267115`. Image ID:
`sha256:6fc88e1017a90d77695a332d6410691868bdedfeb3f334ae7ac380ae97a447ab`. The report was created at
`2026-09-07T20:09:43.425951899Z`.

The snapshot and compatible pins were applied before the new scan. Its HIGH/CRITICAL residual
exactly matches the 129 reviewed IDs. OpenVEX v4 retains the existing 55 decisions and adds 129
decisions restricted to `linux-libc-dev@6.8.0-139.139`, Ubuntu 24.04, **amd64 only**. The six fixed
CVEs receive no new statement. New statements cannot suppress the old `.136` package or unobserved
arm64 findings; both architectures' package evidence remains available for review.

This is a package-content applicability finding. It does not qualify the host kernel, CPU, firmware,
GPU drivers, separately installed perf tools, or the complete container image.

## Ubuntu snapshot and payload evidence

The applied snapshot is `20260908T000000Z`. Both `noble-updates` and `noble-security` indexes
publish the following packages for both architectures, and the actual DEBs were downloaded without
installation. The compressed indexes match SHA256/size entries in their retrieved InRelease files,
and the DEBs match their package-index SHA256 fields. InRelease signatures were not verified
locally. The subsequent CI log records successful signed APT retrieval and installation for amd64,
as detailed below; arm64 build validation remains pending.

| Architecture | Package version | File count (excluding directories) | DEB SHA256 | Primary Ubuntu payload |
| --- | --- | ---: | --- | --- |
| amd64 | 6.8.0-139.139 | 990 | `f8292b3414cac372ec28ba484a45e3f18b3ac5fc7872ca82661835286f1c5865` | [snapshot DEB](https://snapshot.ubuntu.com/ubuntu/20260908T000000Z/pool/main/l/linux/linux-libc-dev_6.8.0-139.139_amd64.deb) |
| arm64 | 6.8.0-139.139 | 962 | `673684ae380e365c4aacbba22ee233d7d2aebe695a87d4dbc62cf873febb970a` | [snapshot DEB](https://snapshot.ubuntu.com/ubuntu/20260908T000000Z/pool/main/l/linux/linux-libc-dev_6.8.0-139.139_arm64.deb) |

The amd64 payload has 988 `.h` files plus copyright/changelog; arm64 has 960 `.h` files plus
copyright/changelog. The baseline `20260726T000000Z` DEBs at version `6.8.0-136.136` were
independently downloaded, checked and inventoried too; their counts are the same. No executable,
kernel image, module, `.c` implementation, or perf executable is in these package payloads. Exported
headers can contain inline code, so a `.h` suffix alone was not used as an exemption rule: every CNA
program-file path was inspected, including the one UAPI-path overlap below.

[Ubuntu package metadata](https://packages.ubuntu.com/noble/linux-libc-dev) identifies the binary's
source package and purpose, but its mixed per-architecture release display is not proof of
cross-architecture snapshot availability. The inspected snapshot indexes and DEBs above provide that
proof. [Ubuntu's snapshot documentation](https://snapshot.ubuntu.com/) defines the timestamped
archive interface.

| Pin | Previous | Applied | Reason |
| --- | --- | --- | --- |
| `UBUNTU_SNAPSHOT` (Dockerfile/Bake) | `20260726T000000Z` | `20260908T000000Z` | Verified indexes/payloads on both architectures |
| `LINUX_LIBC_DEV_VERSION` (Dockerfile/Bake) | `6.8.0-136.136` | `6.8.0-139.139` | Six supplied findings have Ubuntu fixes |
| `OPENSSL_VERSION` (Dockerfile) | `3.0.13-0ubuntu3.11` | `3.0.13-0ubuntu3.15` | New snapshot no longer advertises the old exact pin in any enabled main pocket |
| `CA_CERTIFICATES_VERSION` | `20260601~24.04.1` | unchanged | Still available on both architectures |

Only changing the two original pins is insufficient: the `ubuntu-ca` stage explicitly installs and
checks the OpenSSL version. All four configured pockets (`noble`, `noble-updates`,
`noble-backports`, `noble-security`) were inspected for amd64 and arm64. Release contains OpenSSL
`3.0.13-0ubuntu3`; updates/security contain `.15`; backports has no OpenSSL entry. Keeping `.11`
would leave an unsatisfied exact APT request on this snapshot. No general upgrade, unpinning, header
removal, severity change or ignore-all is proposed.

## Actual rebuilt NVIDIA residual

[CI run 34192891669, NVIDIA job
101954401272](https://github.com/mmkolpakov/robotics-runtime-infra/actions/runs/34192891669/job/101954401272)
completed at `2026-09-08T06:12:12Z`. The build and GPU ABI steps passed; the HIGH/CRITICAL scan gate
failed. The workflow head is `a2f62d356507d2fe842e59447f50eef538d0e011`; checkout used PR merge
`5336df557bf1cefe81cd543ee2925b879180cb6c`, whose second parent is that head. The artifact name and
image revision use this merge SHA, so their different suffix is expected.

Artifact `10043065827`, `security-nvidia-5336df557bf1cefe81cd543ee2925b879180cb6c`, contains one
JSON report and its SARIF. JSON SHA256:
`26bb62b1be763728161d8c32140e7d86e007dcf8b2751964b4a5d584c41b9471`; created
`2026-09-08T06:12:01.318693324Z`; image ID
`sha256:353a7757c1392e8a87266acebb592c24d0b619180249b4bf74d44664bfdb25ac`.

The [portable CI comparison](linux-libc-dev-2026-09-08.ci.json) records all actual residual IDs,
severities, package versions and PURLs, provenance and selected numbered build-log lines. It
confirms:

- **129 HIGH/CRITICAL: 124 HIGH and five CRITICAL**, all
  `pkg:deb/ubuntu/linux-libc-dev@6.8.0-139.139?arch=amd64&distro=ubuntu-24.04` with no reported
  fixed version. The six fixed CVEs are absent from the new report. There are zero unexpected IDs,
  missing candidate IDs or severity mismatches.
- The report also contains 2,431 MEDIUM and 265 LOW findings. Those remain outside these new
  statements; severity and the HIGH/CRITICAL gate are unchanged.
- The merge's snapshot helper specifies `Signed-By` with Ubuntu's archive keyring and strict APT
  update errors. The log records retrieval of snapshot InRelease files and successful installation
  of `.139`. The built VEX document exactly matches the existing v3 baseline. This supplies the
  previously missing amd64 build/scan evidence.
- The final NVIDIA image still has OpenSSL, libssl3t64 and libssl-dev `.11`, with no HIGH/CRITICAL
  findings in this report. The `.15` pin is scoped to the separate `ubuntu-ca` stage; it is not
  evidence that the NVIDIA runtime's OpenSSL was upgraded. No OpenSSL VEX is introduced.
- The scan covers amd64 and one NVIDIA image. Arm64 package contents were reviewed, but no arm64
  residual is present here. Later images in the group may not have been scanned after this gate
  failed. New statements therefore cover only the observed amd64 PURL.

## Cases requiring distinct applicability reasoning

- **CVE-2026-53398 (CRITICAL):** the Linux CNA identifies `fs/nfsd/nfs4xdr.c` (SECINFO_NO_NAME
  decode cleanup). [Ubuntu still marks noble linux
  vulnerable](https://ubuntu.com/security/CVE-2026-53398). The NFSD implementation is absent from
  both reviewed headers packages; this does not establish that the host's NFSD implementation is
  safe.
- **CVE-2026-80668:** the upstream
  [fix](https://github.com/torvalds/linux/commit/b8b09dc2bf35a00d4e0556b5d6308c7b917ebda2) lists
  `include/uapi/linux/netfilter/nf_conntrack_common.h`, which really is exported. Its only change in
  that file adds `NF_CT_EXPECT_DEAD` under `#ifdef __KERNEL__`. The [Linux 6.8 export
  script](https://github.com/torvalds/linux/blob/v6.8/scripts/headers_install.sh) removes such
  sections with `unifdef -U__KERNEL__`. The installed header in all four examined DEBs lacks both
  that macro and the guard, with identical SHA256
  `f96c03a170825a42f0a417efe70d77f05dd4265d7855eb05ba8024a58cc938f8`. The vulnerable timer/refcount
  handling of `exp->master` and the GC replacement are in non-exported netfilter implementation
  code. The exemption is based on the changed code, not just the package label.
- **CVE-2026-80671:** `tools/perf/builtin-sched.c`, specifically `register_pid()` parsing untrusted
  perf.data. This is a userspace perf-tool bug. That source/executable is absent from
  linux-libc-dev. No VEX statement is made about linux-tools or another package containing perf.
- **CVE-2025-10263:** the [Arm CNA record](https://www.cve.org/CVERecord?id=CVE-2025-10263)
  describes CPU TLBI completion errata. [Ubuntu's notes](https://ubuntu.com/security/CVE-2025-10263)
  name `ARM64_WORKAROUND_REPEAT_TLBI`; the [upstream
  mitigation](https://github.com/torvalds/linux/commit/cfd391e74134db664feb499d43af286380b10ba8)
  changes `arch/arm64/kernel/cpu_errata.c`, Kconfig and silicon-errata documentation, with separate
  internal CPU-ID header additions. None is supplied by the UAPI headers package. Arm's linked
  advisory endpoint returned HTTP 403 during this review; the fetched Arm-authored CNA record,
  Ubuntu record and Arm-authored upstream patches establish the package distinction. No host
  mitigation claim is made.
- **Internal headers:** files such as `include/linux/fscrypt.h`, `include/net/tcp.h` and
  `fs/afs/internal.h` can contain vulnerable kernel inline code, but are not exported UAPI headers.
  An installed `usr/include/linux/fscrypt.h` originates from the distinct
  `include/uapi/linux/fscrypt.h` interface; a shared basename is not proof that internal code is
  included. [Linux export
  documentation](https://www.kernel.org/doc/html/latest/kbuild/headers_install.html) defines that
  boundary.

The full set partitions into 132 ordinary non-exported kernel implementation cases (six fixed), one
specially inspected UAPI-path case, one perf-tool case, and one hardware/kernel-mitigation case.

## Per-CVE table

Severity is preserved from the supplied Trivy report even where a current upstream CVSS differs.
Every row links the Ubuntu source-package status, the primary CNA record and an upstream
implementation reference. `Absent` below refers only to the vulnerable implementation in the
reviewed amd64/arm64 linux-libc-dev payloads.

| CVE / reported severity | Ubuntu linux / noble | Implementation and primary references | Header-package applicability / action |
| --- | --- | --- | --- |
| [CVE-2025-10263](https://ubuntu.com/security/CVE-2025-10263) / HIGH | Vulnerable, work in progress | `arch/arm64/kernel/cpu_errata.c`; `arch/arm64/Kconfig`; `arch/arm64/include/asm/cputype.h`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2025/10xxx/CVE-2025-10263.json); [implementation](https://github.com/torvalds/linux/commit/cfd391e74134db664feb499d43af286380b10ba8) | CPU/kernel implementation absent from header package; reviewed amd64 VEX; host still requires independent assessment. |
| [CVE-2025-37906](https://ubuntu.com/security/CVE-2025-37906) / HIGH | Vulnerable | `drivers/block/ublk_drv.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2025/37xxx/CVE-2025-37906.json); [implementation](https://git.kernel.org/stable/c/fb2eb9ddf556f93fef45201e1f9d2b8674bcc975) | Absent; reviewed amd64 VEX |
| [CVE-2025-38717](https://ubuntu.com/security/CVE-2025-38717) / HIGH | Vulnerable | `include/net/kcm.h`; `net/kcm/kcmsock.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2025/38xxx/CVE-2025-38717.json); [implementation](https://git.kernel.org/stable/c/c0bffbc92a1ca3960fb9cdb8e9f75a68468eb308) | Absent; reviewed amd64 VEX |
| [CVE-2025-40025](https://ubuntu.com/security/CVE-2025-40025) / HIGH | Vulnerable | `fs/f2fs/f2fs.h`; `fs/f2fs/gc.c`; `fs/f2fs/node.c`; `fs/f2fs/node.h`; `fs/f2fs/recovery.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2025/40xxx/CVE-2025-40025.json); [implementation](https://git.kernel.org/stable/c/186098f34b8a5d65eb828f952c8cc56272c60ea0) | Absent; reviewed amd64 VEX |
| [CVE-2025-40064](https://ubuntu.com/security/CVE-2025-40064) / HIGH | Vulnerable | `net/smc/smc_pnet.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2025/40xxx/CVE-2025-40064.json); [implementation](https://git.kernel.org/stable/c/005a7173d8e4710646043a681af36f79ce05a29b) | Absent; reviewed amd64 VEX |
| [CVE-2025-40075](https://ubuntu.com/security/CVE-2025-40075) / HIGH | Vulnerable | `net/ipv4/tcp_metrics.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2025/40xxx/CVE-2025-40075.json); [implementation](https://git.kernel.org/stable/c/4b89397807eb04986427c4786d065e9442834ad4) | Absent; reviewed amd64 VEX |
| [CVE-2025-40158](https://ubuntu.com/security/CVE-2025-40158) / HIGH | Vulnerable | `net/ipv6/ip6_output.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2025/40xxx/CVE-2025-40158.json); [implementation](https://git.kernel.org/stable/c/0393f85c3241c19ba8550f04a812e7d19f6b3082) | Absent; reviewed amd64 VEX |
| [CVE-2025-68304](https://ubuntu.com/security/CVE-2025-68304) / HIGH | Vulnerable | `include/net/bluetooth/hci_core.h`; `net/bluetooth/hci_core.c`; `net/bluetooth/iso.c`; `net/bluetooth/l2cap_core.c`; `net/bluetooth/sco.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2025/68xxx/CVE-2025-68304.json); [implementation](https://git.kernel.org/stable/c/ec74cdf77310c43b01b83ee898a9bd4b4b0b8e93) | Absent; reviewed amd64 VEX |
| [CVE-2025-68360](https://ubuntu.com/security/CVE-2025-68360) / HIGH | Vulnerable | `drivers/net/wireless/mediatek/mt76/mt76.h`; `drivers/net/wireless/mediatek/mt76/mt7996/mmio.c`; `drivers/net/wireless/mediatek/mt76/wed.c`; `include/linux/soc/mediatek/mtk_wed.h`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2025/68xxx/CVE-2025-68360.json); [implementation](https://git.kernel.org/stable/c/ab94ecb997fd1bbc501a0116c7aad51556b67c86) | Absent; reviewed amd64 VEX |
| [CVE-2026-53356](https://ubuntu.com/security/CVE-2026-53356) / HIGH | Vulnerable, work in progress | `drivers/gpu/drm/i915/gem/i915_gem_phys.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/53xxx/CVE-2026-53356.json); [implementation](https://git.kernel.org/stable/c/40f738991058eb3e3530c3006a5bd6fd5e29f035) | Absent; reviewed amd64 VEX |
| [CVE-2026-53357](https://ubuntu.com/security/CVE-2026-53357) / HIGH | Fixed 6.8.0-139.139 | `net/bluetooth/af_bluetooth.c`; `net/bluetooth/iso.c`; `net/bluetooth/l2cap_sock.c`; `net/bluetooth/rfcomm/sock.c`; `net/bluetooth/sco.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/53xxx/CVE-2026-53357.json); [implementation](https://git.kernel.org/stable/c/751de6ec671fe75ad9cf65a0638d2a06b6a5984d) | Absent; upgrade, no new VEX |
| [CVE-2026-53362](https://ubuntu.com/security/CVE-2026-53362) / HIGH | Vulnerable | `net/ipv6/ip6_output.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/53xxx/CVE-2026-53362.json); [implementation](https://git.kernel.org/stable/c/14200d435af9a9eeb444f529fc2f689a236b7962) | Absent; reviewed amd64 VEX |
| [CVE-2026-53388](https://ubuntu.com/security/CVE-2026-53388) / HIGH | Vulnerable | `fs/fuse/dev.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/53xxx/CVE-2026-53388.json); [implementation](https://git.kernel.org/stable/c/7c18691e0cfda29672f79bafde8abdb7710674f6) | Absent; reviewed amd64 VEX |
| [CVE-2026-53398](https://ubuntu.com/security/CVE-2026-53398) / CRITICAL | Vulnerable | `fs/nfsd/nfs4xdr.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/53xxx/CVE-2026-53398.json); [implementation](https://git.kernel.org/stable/c/8836405abdc53ca3dd5fc68b2cf6f8f012fad011) | Absent; reviewed amd64 VEX |
| [CVE-2026-53399](https://ubuntu.com/security/CVE-2026-53399) / HIGH | Vulnerable | `fs/nfsd/nfs4layouts.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/53xxx/CVE-2026-53399.json); [implementation](https://git.kernel.org/stable/c/d788ef40a7517d22c97ab01700e4ae4c611b6f2f) | Absent; reviewed amd64 VEX |
| [CVE-2026-63801](https://ubuntu.com/security/CVE-2026-63801) / HIGH | Vulnerable | `net/tipc/crypto.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/63xxx/CVE-2026-63801.json); [implementation](https://git.kernel.org/stable/c/171d31245d11bf84836fad3b394cb465a4d008ec) | Absent; reviewed amd64 VEX |
| [CVE-2026-63809](https://ubuntu.com/security/CVE-2026-63809) / HIGH | Vulnerable | `kernel/bpf/cgroup.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/63xxx/CVE-2026-63809.json); [implementation](https://git.kernel.org/stable/c/d0a81ed5ff5d0f9c3f63a4f9e5a4642c363ecd3e) | Absent; reviewed amd64 VEX |
| [CVE-2026-63815](https://ubuntu.com/security/CVE-2026-63815) / HIGH | Vulnerable | `fs/f2fs/inode.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/63xxx/CVE-2026-63815.json); [implementation](https://git.kernel.org/stable/c/3c8d6b4093aea40a20596f452289e7c22d84e6d5) | Absent; reviewed amd64 VEX |
| [CVE-2026-63823](https://ubuntu.com/security/CVE-2026-63823) / HIGH | Vulnerable | `include/keys/request_key_auth-type.h`; `security/keys/internal.h`; `security/keys/keyctl.c`; `security/keys/request_key_auth.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/63xxx/CVE-2026-63823.json); [implementation](https://git.kernel.org/stable/c/d8274181b0f28d450b42489723a5ba81042158d7) | Absent; reviewed amd64 VEX |
| [CVE-2026-63884](https://ubuntu.com/security/CVE-2026-63884) / HIGH | Vulnerable, work in progress | `drivers/gpu/drm/i915/gem/i915_gem_ttm.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/63xxx/CVE-2026-63884.json); [implementation](https://git.kernel.org/stable/c/df73f3bc731af1c39ac5405bc59c4e7c6f8e9117) | Absent; reviewed amd64 VEX |
| [CVE-2026-63917](https://ubuntu.com/security/CVE-2026-63917) / HIGH | Vulnerable, work in progress | `net/ipv6/ip6_vti.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/63xxx/CVE-2026-63917.json); [implementation](https://git.kernel.org/stable/c/0cdce7618464f7fb06f461e8f4ad575cb1d570f4) | Absent; reviewed amd64 VEX |
| [CVE-2026-63926](https://ubuntu.com/security/CVE-2026-63926) / HIGH | Vulnerable, work in progress | `net/core/filter.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/63xxx/CVE-2026-63926.json); [implementation](https://git.kernel.org/stable/c/f14609d8146707452e0822f3c8154674ce677251) | Absent; reviewed amd64 VEX |
| [CVE-2026-63940](https://ubuntu.com/security/CVE-2026-63940) / CRITICAL | Vulnerable | `arch/x86/kvm/svm/sev.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/63xxx/CVE-2026-63940.json); [implementation](https://git.kernel.org/stable/c/3b6035bc6bff20e89752ce4358bc4c9a9d5883f2) | Absent; reviewed amd64 VEX |
| [CVE-2026-63946](https://ubuntu.com/security/CVE-2026-63946) / HIGH | Vulnerable, work in progress | `net/bluetooth/iso.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/63xxx/CVE-2026-63946.json); [implementation](https://git.kernel.org/stable/c/c57ea90f203c8b8b41a474f19a09000d0f841436) | Absent; reviewed amd64 VEX |
| [CVE-2026-63954](https://ubuntu.com/security/CVE-2026-63954) / HIGH | Vulnerable, work in progress | `fs/hpfs/alloc.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/63xxx/CVE-2026-63954.json); [implementation](https://git.kernel.org/stable/c/010b08084000ef018f1a8de5197087f3b91d8cfe) | Absent; reviewed amd64 VEX |
| [CVE-2026-63971](https://ubuntu.com/security/CVE-2026-63971) / HIGH | Vulnerable, work in progress | `net/sctp/socket.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/63xxx/CVE-2026-63971.json); [implementation](https://git.kernel.org/stable/c/0e0d5bc76fd4267a71334fcc8f1a5fbcf997845d) | Absent; reviewed amd64 VEX |
| [CVE-2026-63974](https://ubuntu.com/security/CVE-2026-63974) / HIGH | Vulnerable, work in progress | `net/bluetooth/hci_sync.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/63xxx/CVE-2026-63974.json); [implementation](https://git.kernel.org/stable/c/9cebe4680bb9a72f80c6541eb24af06db7a1fbc9) | Absent; reviewed amd64 VEX |
| [CVE-2026-63976](https://ubuntu.com/security/CVE-2026-63976) / HIGH | Vulnerable, work in progress | `net/bluetooth/l2cap_core.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/63xxx/CVE-2026-63976.json); [implementation](https://git.kernel.org/stable/c/59f5ecf6ad5c4db6ae81965a96156954a3b0d89a) | Absent; reviewed amd64 VEX |
| [CVE-2026-64002](https://ubuntu.com/security/CVE-2026-64002) / HIGH | Vulnerable, work in progress | `net/ipv4/sysctl_net_ipv4.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64002.json); [implementation](https://git.kernel.org/stable/c/ecf45080a4d3f4526cacb8b14060fe3b49a6913b) | Absent; reviewed amd64 VEX |
| [CVE-2026-64005](https://ubuntu.com/security/CVE-2026-64005) / HIGH | Vulnerable, work in progress | `net/smc/af_smc.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64005.json); [implementation](https://git.kernel.org/stable/c/cdc79c05cc375f68ae87b0c74fdaac1a5c93155a) | Absent; reviewed amd64 VEX |
| [CVE-2026-64015](https://ubuntu.com/security/CVE-2026-64015) / HIGH | Fixed 6.8.0-139.139 | `security/keys/keyring.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64015.json); [implementation](https://git.kernel.org/stable/c/4c5d407ba3ff7f30561ff73ba1b07ed70c864edc) | Absent; upgrade, no new VEX |
| [CVE-2026-64018](https://ubuntu.com/security/CVE-2026-64018) / HIGH | Fixed 6.8.0-139.139 | `drivers/net/ethernet/microsoft/mana/hw_channel.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64018.json); [implementation](https://git.kernel.org/stable/c/5ddc715324badd7f2641bc177db1d027b402adae) | Absent; upgrade, no new VEX |
| [CVE-2026-64032](https://ubuntu.com/security/CVE-2026-64032) / HIGH | Fixed 6.8.0-139.139 | `net/bridge/br_multicast.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64032.json); [implementation](https://git.kernel.org/stable/c/ddefd1b8e5eb58933a697ab38334f0fd82e7fb8b) | Absent; upgrade, no new VEX |
| [CVE-2026-64073](https://ubuntu.com/security/CVE-2026-64073) / HIGH | Fixed 6.8.0-139.139 | `kernel/irq_work.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64073.json); [implementation](https://git.kernel.org/stable/c/2dc79362302922cb18f35e262712b5e58de65442) | Absent; upgrade, no new VEX |
| [CVE-2026-64091](https://ubuntu.com/security/CVE-2026-64091) / HIGH | Vulnerable, work in progress | `net/batman-adv/translation-table.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64091.json); [implementation](https://git.kernel.org/stable/c/e4236bf3ec8d6bb15d0d8d825dcf9933a7d6666b) | Absent; reviewed amd64 VEX |
| [CVE-2026-64093](https://ubuntu.com/security/CVE-2026-64093) / HIGH | Vulnerable, work in progress | `net/batman-adv/tp_meter.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64093.json); [implementation](https://git.kernel.org/stable/c/00bf4bb9947b1190a8be8d9b6a1bcbfa3707785c) | Absent; reviewed amd64 VEX |
| [CVE-2026-64115](https://ubuntu.com/security/CVE-2026-64115) / HIGH | Fixed 6.8.0-139.139 | `net/vmw_vsock/vmci_transport.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64115.json); [implementation](https://git.kernel.org/stable/c/1e19f08552b90070ed18bafb1763c78297823af6) | Absent; upgrade, no new VEX |
| [CVE-2026-64123](https://ubuntu.com/security/CVE-2026-64123) / HIGH | Vulnerable, work in progress | `net/hsr/hsr_framereg.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64123.json); [implementation](https://git.kernel.org/stable/c/0ea70fb46940620848c08d9d399455c9e82fecdb) | Absent; reviewed amd64 VEX |
| [CVE-2026-64188](https://ubuntu.com/security/CVE-2026-64188) / HIGH | Vulnerable | `drivers/net/ethernet/qualcomm/rmnet/rmnet_config.c`; `drivers/net/ethernet/qualcomm/rmnet/rmnet_config.h`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64188.json); [implementation](https://git.kernel.org/stable/c/c4e676c3505c5058922dc1a6f1ded795f6758135) | Absent; reviewed amd64 VEX |
| [CVE-2026-64191](https://ubuntu.com/security/CVE-2026-64191) / HIGH | Vulnerable | `drivers/i2c/i2c-stub.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64191.json); [implementation](https://git.kernel.org/stable/c/7e9072dbd5f2f17934751873450d2c22080ead80) | Absent; reviewed amd64 VEX |
| [CVE-2026-64266](https://ubuntu.com/security/CVE-2026-64266) / HIGH | Vulnerable | `fs/fuse/dev.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64266.json); [implementation](https://git.kernel.org/stable/c/1f9156714592356b4fda57beac7eab9c2a462dd3) | Absent; reviewed amd64 VEX |
| [CVE-2026-64269](https://ubuntu.com/security/CVE-2026-64269) / HIGH | Vulnerable | `drivers/infiniband/ulp/rtrs/rtrs-srv.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64269.json); [implementation](https://git.kernel.org/stable/c/a35b7a8728a53ddc80b323970689fa5985816836) | Absent; reviewed amd64 VEX |
| [CVE-2026-64276](https://ubuntu.com/security/CVE-2026-64276) / HIGH | Vulnerable | `drivers/input/rmi4/rmi_f30.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64276.json); [implementation](https://git.kernel.org/stable/c/8c6d18d61bb6fe0e6edf848413391c590552e8a9) | Absent; reviewed amd64 VEX |
| [CVE-2026-64361](https://ubuntu.com/security/CVE-2026-64361) / HIGH | Vulnerable | `fs/hfs/bnode.c`; `fs/hfsplus/hfsplus_fs.h`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64361.json); [implementation](https://git.kernel.org/stable/c/c8dd112173c02adf539fe2ad34a45f5e0068780d) | Absent; reviewed amd64 VEX |
| [CVE-2026-64380](https://ubuntu.com/security/CVE-2026-64380) / HIGH | Vulnerable | `fs/smb/client/smb2pdu.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64380.json); [implementation](https://git.kernel.org/stable/c/171605aed68380c2fa75dff9b3a1ed427c50065b) | Absent; reviewed amd64 VEX |
| [CVE-2026-64383](https://ubuntu.com/security/CVE-2026-64383) / HIGH | Vulnerable | `fs/smb/client/smb2pdu.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64383.json); [implementation](https://git.kernel.org/stable/c/6e27f40b682a5e42a2daae3ce6d96f0e0e16dedb) | Absent; reviewed amd64 VEX |
| [CVE-2026-64385](https://ubuntu.com/security/CVE-2026-64385) / HIGH | Vulnerable | `fs/smb/client/smb2pdu.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64385.json); [implementation](https://git.kernel.org/stable/c/0be4bc64882edaefaaee8d1e27d083643eb778e6) | Absent; reviewed amd64 VEX |
| [CVE-2026-64386](https://ubuntu.com/security/CVE-2026-64386) / HIGH | Vulnerable | `fs/smb/client/smb2pdu.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64386.json); [implementation](https://git.kernel.org/stable/c/100fb7c455fa86d248b8bd7bb9de757c192870b4) | Absent; reviewed amd64 VEX |
| [CVE-2026-64387](https://ubuntu.com/security/CVE-2026-64387) / HIGH | Vulnerable | `fs/smb/client/smb2pdu.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64387.json); [implementation](https://git.kernel.org/stable/c/3409aedf3c81a810243da94164f6621c9d205c98) | Absent; reviewed amd64 VEX |
| [CVE-2026-64390](https://ubuntu.com/security/CVE-2026-64390) / HIGH | Vulnerable | `fs/smb/server/smb2pdu.c`; `fs/smb/server/vfs_cache.c`; `fs/smb/server/vfs_cache.h`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64390.json); [implementation](https://git.kernel.org/stable/c/22d38cf75b556c20b039743bdf3654d535b858be) | Absent; reviewed amd64 VEX |
| [CVE-2026-64393](https://ubuntu.com/security/CVE-2026-64393) / HIGH | Vulnerable | `fs/smb/server/smb2pdu.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64393.json); [implementation](https://git.kernel.org/stable/c/5cbabf3a71575cd31bc7785d92d4ab42338a654b) | Absent; reviewed amd64 VEX |
| [CVE-2026-64396](https://ubuntu.com/security/CVE-2026-64396) / HIGH | Vulnerable | `fs/smb/server/smb2pdu.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64396.json); [implementation](https://git.kernel.org/stable/c/367c42a611fe488b7b03f1f6737f4dee0e8b20a2) | Absent; reviewed amd64 VEX |
| [CVE-2026-64423](https://ubuntu.com/security/CVE-2026-64423) / HIGH | Vulnerable | `net/ipv4/igmp.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64423.json); [implementation](https://git.kernel.org/stable/c/412ba7def06ffe974ba9a1d862b022362c54ffa5) | Absent; reviewed amd64 VEX |
| [CVE-2026-64432](https://ubuntu.com/security/CVE-2026-64432) / HIGH | Vulnerable | `fs/ntfs3/fslog.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64432.json); [implementation](https://git.kernel.org/stable/c/964c3fae1dfc49dde5468eace940f199cda234e9) | Absent; reviewed amd64 VEX |
| [CVE-2026-64440](https://ubuntu.com/security/CVE-2026-64440) / HIGH | Vulnerable | `drivers/staging/rtl8723bs/core/rtw_wlan_util.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64440.json); [implementation](https://git.kernel.org/stable/c/37f642d47c3648a707df3ceb092eee1adffbfd28) | Absent; reviewed amd64 VEX |
| [CVE-2026-64441](https://ubuntu.com/security/CVE-2026-64441) / HIGH | Vulnerable | `drivers/staging/rtl8723bs/core/rtw_ieee80211.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64441.json); [implementation](https://git.kernel.org/stable/c/efa27d487abcdec79669a60a6d94d5d6eceb7c1d) | Absent; reviewed amd64 VEX |
| [CVE-2026-64442](https://ubuntu.com/security/CVE-2026-64442) / HIGH | Vulnerable | `drivers/staging/rtl8723bs/core/rtw_mlme_ext.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64442.json); [implementation](https://git.kernel.org/stable/c/bc881c9915c4468747d0ca5fd1abd7b313cfb0f4) | Absent; reviewed amd64 VEX |
| [CVE-2026-64535](https://ubuntu.com/security/CVE-2026-64535) / CRITICAL | Vulnerable | `drivers/nvme/target/tcp.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64535.json); [implementation](https://git.kernel.org/stable/c/dfb902462bca478f050224ec7a7195aafa7643b1) | Absent; reviewed amd64 VEX |
| [CVE-2026-64543](https://ubuntu.com/security/CVE-2026-64543) / HIGH | Vulnerable | `net/tipc/core.c`; `net/tipc/discover.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64543.json); [implementation](https://git.kernel.org/stable/c/380413cdfd29fb9fa486c82889132b680c4983c5) | Absent; reviewed amd64 VEX |
| [CVE-2026-64548](https://ubuntu.com/security/CVE-2026-64548) / HIGH | Vulnerable | `net/core/filter.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64548.json); [implementation](https://git.kernel.org/stable/c/f1644c9508d24f50dd9e8ebe8d3ba86e0996d2f5) | Absent; reviewed amd64 VEX |
| [CVE-2026-64554](https://ubuntu.com/security/CVE-2026-64554) / HIGH | Vulnerable | `net/ipv6/netfilter.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64554.json); [implementation](https://git.kernel.org/stable/c/8c10778ec674b67a07ea042fcba64270f3f38a5a) | Absent; reviewed amd64 VEX |
| [CVE-2026-64557](https://ubuntu.com/security/CVE-2026-64557) / HIGH | Vulnerable | `include/net/bluetooth/l2cap.h`; `net/bluetooth/6lowpan.c`; `net/bluetooth/l2cap_core.c`; `net/bluetooth/l2cap_sock.c`; `net/bluetooth/smp.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64557.json); [implementation](https://git.kernel.org/stable/c/b39298044e5534612511a2ff5de03ba5f6e7a820) | Absent; reviewed amd64 VEX |
| [CVE-2026-64562](https://ubuntu.com/security/CVE-2026-64562) / HIGH | Vulnerable | `arch/x86/kvm/vmx/nested.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64562.json); [implementation](https://git.kernel.org/stable/c/b82c3144d8264265448292ca406f60bafeba3b6f) | Absent; reviewed amd64 VEX |
| [CVE-2026-64564](https://ubuntu.com/security/CVE-2026-64564) / CRITICAL | Vulnerable | `net/sctp/sm_make_chunk.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64564.json); [implementation](https://git.kernel.org/stable/c/a9ce31be4cb1a5dd82b3e0a1d0c3e7cbdcd31293) | Absent; reviewed amd64 VEX |
| [CVE-2026-64567](https://ubuntu.com/security/CVE-2026-64567) / HIGH | Vulnerable | `fs/btrfs/free-space-cache.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64567.json); [implementation](https://git.kernel.org/stable/c/8ded74c654a982dc8581a17b0caa7fcedb20de69) | Absent; reviewed amd64 VEX |
| [CVE-2026-64597](https://ubuntu.com/security/CVE-2026-64597) / HIGH | Vulnerable | `fs/smb/client/smb2pdu.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/64xxx/CVE-2026-64597.json); [implementation](https://git.kernel.org/stable/c/037511726228aaf165c7067ff2bfc88eaecdf1f3) | Absent; reviewed amd64 VEX |
| [CVE-2026-68085](https://ubuntu.com/security/CVE-2026-68085) / HIGH | Vulnerable | `drivers/bluetooth/hci_ldisc.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/68xxx/CVE-2026-68085.json); [implementation](https://git.kernel.org/stable/c/d52446b3e735cfdbdc2a58342163803bc2e64249) | Absent; reviewed amd64 VEX |
| [CVE-2026-68098](https://ubuntu.com/security/CVE-2026-68098) / HIGH | Vulnerable | `fs/smb/server/smbacl.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/68xxx/CVE-2026-68098.json); [implementation](https://git.kernel.org/stable/c/6d9d7aa4a2c99c31acfa28921c30b684110cf66c) | Absent; reviewed amd64 VEX |
| [CVE-2026-68117](https://ubuntu.com/security/CVE-2026-68117) / HIGH | Vulnerable | `net/tipc/socket.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/68xxx/CVE-2026-68117.json); [implementation](https://git.kernel.org/stable/c/efebc23e9b29e3e5a9e2127dd066929f7f0d315e) | Absent; reviewed amd64 VEX |
| [CVE-2026-68121](https://ubuntu.com/security/CVE-2026-68121) / HIGH | Vulnerable | `drivers/net/ppp/pppoe.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/68xxx/CVE-2026-68121.json); [implementation](https://git.kernel.org/stable/c/7a56e7c9b08e08fd55a1bcada24cf4fe3782b722) | Absent; reviewed amd64 VEX |
| [CVE-2026-68147](https://ubuntu.com/security/CVE-2026-68147) / HIGH | Vulnerable | `fs/crypto/inline_crypt.c`; `fs/f2fs/super.c`; `include/linux/fscrypt.h`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/68xxx/CVE-2026-68147.json); [implementation](https://git.kernel.org/stable/c/bab016bb80d74a9d1f7d4121a7fc1cb529b470e0) | Absent; reviewed amd64 VEX |
| [CVE-2026-68162](https://ubuntu.com/security/CVE-2026-68162) / HIGH | Vulnerable | `net/sctp/protocol.c`; `net/sctp/sysctl.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/68xxx/CVE-2026-68162.json); [implementation](https://git.kernel.org/stable/c/19573dcddb8819fd68d6cd1f916c1c99c3fa4ff4) | Absent; reviewed amd64 VEX |
| [CVE-2026-68189](https://ubuntu.com/security/CVE-2026-68189) / HIGH | Vulnerable | `net/bluetooth/hci_sync.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/68xxx/CVE-2026-68189.json); [implementation](https://git.kernel.org/stable/c/30bc6248f035a792d1b1f4cc761b32fd5827b55f) | Absent; reviewed amd64 VEX |
| [CVE-2026-68196](https://ubuntu.com/security/CVE-2026-68196) / HIGH | Vulnerable | `drivers/net/wireless/microchip/wilc1000/hif.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/68xxx/CVE-2026-68196.json); [implementation](https://git.kernel.org/stable/c/d79b92417f33424ff23dad76716ed8f2cefb1083) | Absent; reviewed amd64 VEX |
| [CVE-2026-68198](https://ubuntu.com/security/CVE-2026-68198) / HIGH | Vulnerable | `drivers/net/wireless/ath/ath6kl/txrx.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/68xxx/CVE-2026-68198.json); [implementation](https://git.kernel.org/stable/c/a1bac650b2d6b1baab1f3e78e2e007a6e2948dde) | Absent; reviewed amd64 VEX |
| [CVE-2026-68199](https://ubuntu.com/security/CVE-2026-68199) / HIGH | Vulnerable | `drivers/net/wireless/ath/ath6kl/txrx.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/68xxx/CVE-2026-68199.json); [implementation](https://git.kernel.org/stable/c/c8e3ca7954d8233fbc54bd370c1827670f43c538) | Absent; reviewed amd64 VEX |
| [CVE-2026-68204](https://ubuntu.com/security/CVE-2026-68204) / HIGH | Vulnerable | `drivers/media/test-drivers/vivid/vivid-ctrls.c`; `drivers/media/test-drivers/vivid/vivid-vid-cap.c`; `drivers/media/test-drivers/vivid/vivid-vid-out.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/68xxx/CVE-2026-68204.json); [implementation](https://git.kernel.org/stable/c/0a820f03727b509b887f3216a574062948761f34) | Absent; reviewed amd64 VEX |
| [CVE-2026-68236](https://ubuntu.com/security/CVE-2026-68236) / HIGH | Vulnerable | `drivers/gpu/drm/amd/display/amdgpu_dm/amdgpu_dm.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/68xxx/CVE-2026-68236.json); [implementation](https://git.kernel.org/stable/c/ba8bf1dcbb44773e7a0fd13b42925c644e0d5e76) | Absent; reviewed amd64 VEX |
| [CVE-2026-68257](https://ubuntu.com/security/CVE-2026-68257) / HIGH | Vulnerable | `drivers/gpu/drm/amd/amdkfd/kfd_queue.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/68xxx/CVE-2026-68257.json); [implementation](https://git.kernel.org/stable/c/b88ffe6593607364a8c06a48c6f29e55437cdf8e) | Absent; reviewed amd64 VEX |
| [CVE-2026-68284](https://ubuntu.com/security/CVE-2026-68284) / HIGH | Vulnerable | `net/ipv4/tcp_bpf.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/68xxx/CVE-2026-68284.json); [implementation](https://git.kernel.org/stable/c/0688e6fe599d2d39147ae9ece97944c6e1815ebf) | Absent; reviewed amd64 VEX |
| [CVE-2026-68323](https://ubuntu.com/security/CVE-2026-68323) / HIGH | Vulnerable | `net/tipc/udp_media.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/68xxx/CVE-2026-68323.json); [implementation](https://git.kernel.org/stable/c/d70c81001df9320d3445e664428a1d408b5ba896) | Absent; reviewed amd64 VEX |
| [CVE-2026-68329](https://ubuntu.com/security/CVE-2026-68329) / HIGH | Vulnerable | `drivers/iommu/amd/iommu.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/68xxx/CVE-2026-68329.json); [implementation](https://git.kernel.org/stable/c/ab7faf5a172ebfdc423ebb3eea4d472740de82f9) | Absent; reviewed amd64 VEX |
| [CVE-2026-68399](https://ubuntu.com/security/CVE-2026-68399) / HIGH | Vulnerable | `net/core/bpf_sk_storage.c`; `net/core/sock.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/68xxx/CVE-2026-68399.json); [implementation](https://git.kernel.org/stable/c/14b49b5ab29979552c219a09e569b424fbbf4a6e) | Absent; reviewed amd64 VEX |
| [CVE-2026-68442](https://ubuntu.com/security/CVE-2026-68442) / HIGH | Vulnerable | `fs/btrfs/extent_map.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/68xxx/CVE-2026-68442.json); [implementation](https://git.kernel.org/stable/c/2a9246a424f45f33a1b8367052611ebe874868ad) | Absent; reviewed amd64 VEX |
| [CVE-2026-68446](https://ubuntu.com/security/CVE-2026-68446) / HIGH | Vulnerable | `drivers/gpu/drm/vmwgfx/vmwgfx_surface.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/68xxx/CVE-2026-68446.json); [implementation](https://git.kernel.org/stable/c/e949adf2d42678fb391a41db277e2fcb12090566) | Absent; reviewed amd64 VEX |
| [CVE-2026-68451](https://ubuntu.com/security/CVE-2026-68451) / HIGH | Vulnerable | `drivers/s390/crypto/zcrypt_ccamisc.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/68xxx/CVE-2026-68451.json); [implementation](https://git.kernel.org/stable/c/7dc306ff7c4d951582adaae65e0aee9fb4968dbe) | Absent; reviewed amd64 VEX |
| [CVE-2026-68470](https://ubuntu.com/security/CVE-2026-68470) / HIGH | Vulnerable | `net/mac80211/rx.c`; `net/mac80211/util.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/68xxx/CVE-2026-68470.json); [implementation](https://git.kernel.org/stable/c/625fc704b19cb48d7d269ad54ffffb4d3bf9c7ed) | Absent; reviewed amd64 VEX |
| [CVE-2026-72024](https://ubuntu.com/security/CVE-2026-72024) / HIGH | Vulnerable | `net/mac802154/iface.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/72xxx/CVE-2026-72024.json); [implementation](https://git.kernel.org/stable/c/72ac5af9ad09662bd0ea91cb8845d490c8ef9c01) | Absent; reviewed amd64 VEX |
| [CVE-2026-72110](https://ubuntu.com/security/CVE-2026-72110) / HIGH | Vulnerable | `kernel/fork.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/72xxx/CVE-2026-72110.json); [implementation](https://git.kernel.org/stable/c/7df67a4799067a59e6a2d53f8059a6be6e73e678) | Absent; reviewed amd64 VEX |
| [CVE-2026-72111](https://ubuntu.com/security/CVE-2026-72111) / HIGH | Vulnerable | `kernel/bpf/verifier.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/72xxx/CVE-2026-72111.json); [implementation](https://git.kernel.org/stable/c/bde92f65042ec14389782dd223f706bf6b59ce5d) | Absent; reviewed amd64 VEX |
| [CVE-2026-72123](https://ubuntu.com/security/CVE-2026-72123) / HIGH | Vulnerable | `net/can/bcm.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/72xxx/CVE-2026-72123.json); [implementation](https://git.kernel.org/stable/c/de5fce46637de05bef56ec08528127676eb6fc9b) | Absent; reviewed amd64 VEX |
| [CVE-2026-72124](https://ubuntu.com/security/CVE-2026-72124) / HIGH | Vulnerable | `net/can/isotp.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/72xxx/CVE-2026-72124.json); [implementation](https://git.kernel.org/stable/c/bbedeb67a9a684f2fb78c55bd3662c400526715e) | Absent; reviewed amd64 VEX |
| [CVE-2026-72135](https://ubuntu.com/security/CVE-2026-72135) / HIGH | Vulnerable | `drivers/char/tpm/tpm-dev.c`; `drivers/char/tpm/tpmrm-dev.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/72xxx/CVE-2026-72135.json); [implementation](https://git.kernel.org/stable/c/ed0ffc2c016629e40ba041ed0424a772d8b02e2c) | Absent; reviewed amd64 VEX |
| [CVE-2026-72195](https://ubuntu.com/security/CVE-2026-72195) / HIGH | Vulnerable | `fs/ntfs3/fslog.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/72xxx/CVE-2026-72195.json); [implementation](https://git.kernel.org/stable/c/ab8761676d638c5be170aaf91b7ffdd451236616) | Absent; reviewed amd64 VEX |
| [CVE-2026-72288](https://ubuntu.com/security/CVE-2026-72288) / HIGH | Vulnerable | `arch/arm64/kvm/vgic/vgic.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/72xxx/CVE-2026-72288.json); [implementation](https://git.kernel.org/stable/c/d19dca8194ebed371e624331c6be2cb73b562caf) | Absent; reviewed amd64 VEX |
| [CVE-2026-72338](https://ubuntu.com/security/CVE-2026-72338) / HIGH | Vulnerable | `include/net/tc_act/tc_pedit.h`; `net/sched/act_api.c`; `net/sched/act_pedit.c`; `net/sched/cls_api.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/72xxx/CVE-2026-72338.json); [implementation](https://git.kernel.org/stable/c/0d8532a5e972a5351cf4ee4a435e0d65cbba8f23) | Absent; reviewed amd64 VEX |
| [CVE-2026-72390](https://ubuntu.com/security/CVE-2026-72390) / HIGH | Vulnerable | `net/sched/sch_teql.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/72xxx/CVE-2026-72390.json); [implementation](https://git.kernel.org/stable/c/03c67781254c574ae7fa75e881239a78473bdf42) | Absent; reviewed amd64 VEX |
| [CVE-2026-72472](https://ubuntu.com/security/CVE-2026-72472) / HIGH | Vulnerable | `fs/nfs/delegation.c`; `fs/nfs/nfs4proc.c`; `include/linux/nfs_xdr.h`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/72xxx/CVE-2026-72472.json); [implementation](https://git.kernel.org/stable/c/1cda95bf2e9c0e6b63545b7565fe4a1e474322f4) | Absent; reviewed amd64 VEX |
| [CVE-2026-72478](https://ubuntu.com/security/CVE-2026-72478) / HIGH | Vulnerable | `fs/ntfs3/fslog.c`; `fs/ntfs3/ntfs_fs.h`; `fs/ntfs3/run.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/72xxx/CVE-2026-72478.json); [implementation](https://git.kernel.org/stable/c/c69b9003332917b652175d5fa9d84158c5ed8617) | Absent; reviewed amd64 VEX |
| [CVE-2026-74268](https://ubuntu.com/security/CVE-2026-74268) / HIGH | Vulnerable | `include/net/tcp.h`; `net/ipv4/inet_connection_sock.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/74xxx/CVE-2026-74268.json); [implementation](https://git.kernel.org/stable/c/ce311bd2e36596f0aa2c92ca86fb3e019ac57eae) | Absent; reviewed amd64 VEX |
| [CVE-2026-74317](https://ubuntu.com/security/CVE-2026-74317) / HIGH | Vulnerable | `drivers/net/ethernet/intel/ixgbe/ixgbe_main.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/74xxx/CVE-2026-74317.json); [implementation](https://git.kernel.org/stable/c/a2a224f5e344ccb1ec3693a0735822db9214e2ca) | Absent; reviewed amd64 VEX |
| [CVE-2026-74334](https://ubuntu.com/security/CVE-2026-74334) / HIGH | Vulnerable | `drivers/infiniband/core/nldev.c`; `drivers/infiniband/core/restrack.c`; `drivers/infiniband/core/restrack.h`; `drivers/infiniband/core/uverbs_cmd.c`; `include/rdma/ib_verbs.h`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/74xxx/CVE-2026-74334.json); [implementation](https://git.kernel.org/stable/c/1a132ee4e655288d9a0937ea5109a0d038431ae9) | Absent; reviewed amd64 VEX |
| [CVE-2026-74341](https://ubuntu.com/security/CVE-2026-74341) / HIGH | Vulnerable | `drivers/net/wireless/ath/wcn36xx/smd.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/74xxx/CVE-2026-74341.json); [implementation](https://git.kernel.org/stable/c/dae9cadf0925f1cbfb71306d60490890df3870a6) | Absent; reviewed amd64 VEX |
| [CVE-2026-74363](https://ubuntu.com/security/CVE-2026-74363) / HIGH | Vulnerable | `kernel/bpf/inode.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/74xxx/CVE-2026-74363.json); [implementation](https://git.kernel.org/stable/c/ea1c243c39e32b7fc1c2edfe32081ff7e30a877c) | Absent; reviewed amd64 VEX |
| [CVE-2026-74378](https://ubuntu.com/security/CVE-2026-74378) / HIGH | Vulnerable | `drivers/infiniband/sw/rxe/rxe_resp.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/74xxx/CVE-2026-74378.json); [implementation](https://git.kernel.org/stable/c/3cfa2a3adc51b7c57729961a03446962ff10e3d2) | Absent; reviewed amd64 VEX |
| [CVE-2026-74390](https://ubuntu.com/security/CVE-2026-74390) / HIGH | Vulnerable | `drivers/infiniband/hw/irdma/verbs.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/74xxx/CVE-2026-74390.json); [implementation](https://git.kernel.org/stable/c/4780f58672ee6328accd54a95f9c00683477e499) | Absent; reviewed amd64 VEX |
| [CVE-2026-74394](https://ubuntu.com/security/CVE-2026-74394) / CRITICAL | Vulnerable | `drivers/infiniband/ulp/srpt/ib_srpt.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/74xxx/CVE-2026-74394.json); [implementation](https://git.kernel.org/stable/c/c82c860f8c8e4f4f454c9f14d0ad0c0466965f7d) | Absent; reviewed amd64 VEX |
| [CVE-2026-74411](https://ubuntu.com/security/CVE-2026-74411) / HIGH | Vulnerable | `drivers/net/wireless/realtek/rtw89/fw.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/74xxx/CVE-2026-74411.json); [implementation](https://git.kernel.org/stable/c/966fbed4b4463fbcb49c5becf3f86eae776861bd) | Absent; reviewed amd64 VEX |
| [CVE-2026-74427](https://ubuntu.com/security/CVE-2026-74427) / HIGH | Vulnerable | `fs/afs/rxrpc.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/74xxx/CVE-2026-74427.json); [implementation](https://git.kernel.org/stable/c/63ccaf1bdf8be2330f47f9b5b233dd3fd04acbd9) | Absent; reviewed amd64 VEX |
| [CVE-2026-74438](https://ubuntu.com/security/CVE-2026-74438) / HIGH | Vulnerable | `arch/arm/configs/sunxi_defconfig`; `drivers/crypto/allwinner/Kconfig`; `drivers/crypto/allwinner/sun4i-ss/Makefile`; `drivers/crypto/allwinner/sun4i-ss/sun4i-ss-core.c`; `drivers/crypto/allwinner/sun4i-ss/sun4i-ss-prng.c`; `drivers/crypto/allwinner/sun4i-ss/sun4i-ss.h`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/74xxx/CVE-2026-74438.json); [implementation](https://git.kernel.org/stable/c/2eafecaba1b46bb9774eaf3556619fd5b6a17c1c) | Absent; reviewed amd64 VEX |
| [CVE-2026-74446](https://ubuntu.com/security/CVE-2026-74446) / HIGH | Vulnerable | `drivers/gpu/drm/amd/amdkfd/kfd_events.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/74xxx/CVE-2026-74446.json); [implementation](https://git.kernel.org/stable/c/8f7196f25b14f4290738639a50459b56a5ff2784) | Absent; reviewed amd64 VEX |
| [CVE-2026-74465](https://ubuntu.com/security/CVE-2026-74465) / HIGH | Vulnerable | `net/openvswitch/meter.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/74xxx/CVE-2026-74465.json); [implementation](https://git.kernel.org/stable/c/496f3013c6ff759249abcfb2da2361c1a3e2e66d) | Absent; reviewed amd64 VEX |
| [CVE-2026-74470](https://ubuntu.com/security/CVE-2026-74470) / HIGH | Vulnerable | `drivers/scsi/scsi_debug.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/74xxx/CVE-2026-74470.json); [implementation](https://git.kernel.org/stable/c/7b615fc139e35c81077046df44725c532f7e2404) | Absent; reviewed amd64 VEX |
| [CVE-2026-74506](https://ubuntu.com/security/CVE-2026-74506) / HIGH | Vulnerable | `fs/afs/internal.h`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/74xxx/CVE-2026-74506.json); [implementation](https://git.kernel.org/stable/c/c0d3b81f703b2a9e37fe1347610a50cdf0078c27) | Absent; reviewed amd64 VEX |
| [CVE-2026-74510](https://ubuntu.com/security/CVE-2026-74510) / HIGH | Vulnerable | `net/bluetooth/mgmt.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/74xxx/CVE-2026-74510.json); [implementation](https://git.kernel.org/stable/c/50af4280a587c9971b5388cbc438f1324e626b7b) | Absent; reviewed amd64 VEX |
| [CVE-2026-74534](https://ubuntu.com/security/CVE-2026-74534) / HIGH | Vulnerable | `net/bluetooth/iso.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/74xxx/CVE-2026-74534.json); [implementation](https://git.kernel.org/stable/c/3b921533e8aa95b77aadcf31737595578e735f3c) | Absent; reviewed amd64 VEX |
| [CVE-2026-74535](https://ubuntu.com/security/CVE-2026-74535) / HIGH | Vulnerable | `net/bluetooth/iso.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/74xxx/CVE-2026-74535.json); [implementation](https://git.kernel.org/stable/c/16d89a63e08280abeef7218970a3bbd7ca62b021) | Absent; reviewed amd64 VEX |
| [CVE-2026-80631](https://ubuntu.com/security/CVE-2026-80631) / HIGH | Vulnerable | `fs/btrfs/lzo.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/80xxx/CVE-2026-80631.json); [implementation](https://git.kernel.org/stable/c/1641d058adfbd50cf95d54581ed5d142ee82c07f) | Absent; reviewed amd64 VEX |
| [CVE-2026-80634](https://ubuntu.com/security/CVE-2026-80634) / HIGH | Vulnerable | `net/netfilter/nf_flow_table_path.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/80xxx/CVE-2026-80634.json); [implementation](https://git.kernel.org/stable/c/2f55fa28011c97d6495d5787808db10a8c2d690d) | Absent; reviewed amd64 VEX |
| [CVE-2026-80637](https://ubuntu.com/security/CVE-2026-80637) / HIGH | Vulnerable | `net/netfilter/nf_synproxy_core.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/80xxx/CVE-2026-80637.json); [implementation](https://git.kernel.org/stable/c/2b8e7aaa38002d8ee2f48d87b1f392eadd8e98c4) | Absent; reviewed amd64 VEX |
| [CVE-2026-80644](https://ubuntu.com/security/CVE-2026-80644) / HIGH | Vulnerable | `fs/ocfs2/journal.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/80xxx/CVE-2026-80644.json); [implementation](https://git.kernel.org/stable/c/bf1d59cf2ac8a1730607ebaa0bc0dc6d00f197d0) | Absent; reviewed amd64 VEX |
| [CVE-2026-80668](https://ubuntu.com/security/CVE-2026-80668) / HIGH | Vulnerable | `include/net/netfilter/nf_conntrack_expect.h`; `include/uapi/linux/netfilter/nf_conntrack_common.h`; `net/netfilter/nf_conntrack_core.c`; `net/netfilter/nf_conntrack_expect.c`; `net/netfilter/nf_conntrack_h323_main.c`; `net/netfilter/nf_conntrack_helper.c`; `net/netfilter/nf_conntrack_netlink.c`; `net/netfilter/nf_conntrack_sip.c`; `net/netfilter/nft_ct.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/80xxx/CVE-2026-80668.json); [implementation](https://github.com/torvalds/linux/commit/b8b09dc2bf35a00d4e0556b5d6308c7b917ebda2) | UAPI header present; changed macro is kernel-only and stripped; race code absent. Reviewed amd64 VEX. |
| [CVE-2026-80671](https://ubuntu.com/security/CVE-2026-80671) / HIGH | Vulnerable | `tools/perf/builtin-sched.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/80xxx/CVE-2026-80671.json); [implementation](https://git.kernel.org/stable/c/652cea73b7b7b7c622a2be670e44e3c499c6d49f) | Separate userspace perf tool absent; reviewed amd64 VEX; other perf packages not assessed. |
| [CVE-2026-80681](https://ubuntu.com/security/CVE-2026-80681) / HIGH | Vulnerable | `drivers/net/vxlan/vxlan_core.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/80xxx/CVE-2026-80681.json); [implementation](https://git.kernel.org/stable/c/6375093eb45cd7d89f1945f939eeae3b29d79f56) | Absent; reviewed amd64 VEX |
| [CVE-2026-80691](https://ubuntu.com/security/CVE-2026-80691) / HIGH | Vulnerable | `drivers/target/target_core_iblock.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/80xxx/CVE-2026-80691.json); [implementation](https://git.kernel.org/stable/c/3c60a8b4037dc35e365658fcbcb349a5d742ff49) | Absent; reviewed amd64 VEX |
| [CVE-2026-80692](https://ubuntu.com/security/CVE-2026-80692) / HIGH | Vulnerable | `net/bluetooth/hci_sync.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/80xxx/CVE-2026-80692.json); [implementation](https://git.kernel.org/stable/c/9a77f296aff4b2ca5f2928ab3a3220c82d8b4074) | Absent; reviewed amd64 VEX |
| [CVE-2026-80693](https://ubuntu.com/security/CVE-2026-80693) / HIGH | Vulnerable | `drivers/net/ethernet/intel/idpf/idpf_dev.c`; `drivers/net/ethernet/intel/idpf/idpf_vf_dev.c`; `drivers/net/ethernet/intel/idpf/idpf_virtchnl.c`; `drivers/net/ethernet/intel/idpf/idpf_virtchnl.h`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/80xxx/CVE-2026-80693.json); [implementation](https://git.kernel.org/stable/c/41bb8748124d0d8ee5d8e1eace9dfbc874bc9564) | Absent; reviewed amd64 VEX |
| [CVE-2026-80700](https://ubuntu.com/security/CVE-2026-80700) / HIGH | Vulnerable | `drivers/gpu/drm/vmwgfx/vmwgfx_blit.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/80xxx/CVE-2026-80700.json); [implementation](https://git.kernel.org/stable/c/4e0f669e2951b742239c6fe847fcc406fe78748d) | Absent; reviewed amd64 VEX |
| [CVE-2026-80702](https://ubuntu.com/security/CVE-2026-80702) / HIGH | Vulnerable | `drivers/gpu/drm/vmwgfx/vmwgfx_resource.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/80xxx/CVE-2026-80702.json); [implementation](https://git.kernel.org/stable/c/21bbe38faee4a195d33a93e3908e307807f7745d) | Absent; reviewed amd64 VEX |
| [CVE-2026-80710](https://ubuntu.com/security/CVE-2026-80710) / HIGH | Vulnerable | `drivers/s390/block/dasd_eckd.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/80xxx/CVE-2026-80710.json); [implementation](https://git.kernel.org/stable/c/aca18289c86f22d3fc2f3f6ff615286e7b1702f6) | Absent; reviewed amd64 VEX |
| [CVE-2026-80714](https://ubuntu.com/security/CVE-2026-80714) / HIGH | Vulnerable | `net/netfilter/ipvs/ip_vs_conn.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/80xxx/CVE-2026-80714.json); [implementation](https://git.kernel.org/stable/c/06d1d9b56ef8132fbf85006885eb43d9510b8b02) | Absent; reviewed amd64 VEX |
| [CVE-2026-80716](https://ubuntu.com/security/CVE-2026-80716) / HIGH | Vulnerable | `sound/core/pcm_native.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/80xxx/CVE-2026-80716.json); [implementation](https://git.kernel.org/stable/c/c172e4c53321ee6429955295ea133bc3597a3ca9) | Absent; reviewed amd64 VEX |
| [CVE-2026-80718](https://ubuntu.com/security/CVE-2026-80718) / HIGH | Vulnerable | `mm/percpu-km.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/80xxx/CVE-2026-80718.json); [implementation](https://git.kernel.org/stable/c/5f43d2c1bea280dcdfabaf156c25e7402fb8039f) | Absent; reviewed amd64 VEX |
| [CVE-2026-80721](https://ubuntu.com/security/CVE-2026-80721) / HIGH | Vulnerable | `net/bluetooth/iso.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/80xxx/CVE-2026-80721.json); [implementation](https://git.kernel.org/stable/c/e941799c31f68e67ce0976efb38a79101f921b64) | Absent; reviewed amd64 VEX |
| [CVE-2026-80725](https://ubuntu.com/security/CVE-2026-80725) / HIGH | Vulnerable | `net/core/gro.c`. [CNA](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/80xxx/CVE-2026-80725.json); [implementation](https://git.kernel.org/stable/c/37a5dcd6837fc2afc44a7bc3ed8af4e983783d46) | Absent; reviewed amd64 VEX |

## Validation and handoff

- 135/135 primary CNA records fetched successfully (134 Linux CNA, one Arm CNA); 135/135 Ubuntu
  linux/noble statuses captured. Five transient Ubuntu read timeouts succeeded on retry. All six
  report fixed-version IDs agree with Ubuntu; the other 129 remain source-package
  vulnerable/work-in-progress.
- Four exact DEB payloads inspected: old/new version on amd64/arm64; DEB SHA256 matches their
  snapshot indexes. Candidate indexes were checked across all four configured main pockets and both
  architectures.
- **5/5 `test/ci/security-scanning.bats` tests passed** with Git Bash and native jq using mocked
  Docker. They check VEX v4, exact amd64 package/version scope, 184 total statements, the 129 new
  statements' equality with the actual CI residual, and the applied snapshot/header pins. Both
  actual jq predicates accepted the policy and rejected **11/11 unsafe mutations**, including an
  unobserved CVE, a fixed CVE and an arm64 scope expansion. The original 55 statement objects
  exactly match v3. `git diff --check` passed.
- The separate pin commit changed only Dockerfile/Bake baseline pins, their existing assertions and
  the README baseline. This VEX commit contains no Dockerfile, Bake or healthcheck change.
- The existing HIGH/CRITICAL conversion gate, scan script, trivy.yaml and .trivyignore are
  unchanged. Six fixed findings are addressed by updating packages, not suppressing them. The new
  statements require version `6.8.0-139.139` plus matching architecture/distribution qualifiers.
  This matching behavior is implemented by [go-vex v0.2.7
  PurlMatches](https://github.com/openvex/go-vex/blob/v0.2.7/pkg/vex/vex.go), the dependency pinned
  by [Trivy v0.72.0](https://github.com/aquasecurity/trivy/blob/v0.72.0/go.mod).
- **Not executed locally:** Docker/Trivy image scans, signed APT installation or host/GPU/kernel
  qualification. The downloaded CI evidence supplies the amd64 build and v3 scan result, including
  the six actual removals. A fresh Trivy run with v4 remains required; matching the residual to
  these statements is not a green CI result.

After parent review, run the same scanner and mandatory HIGH/CRITICAL gate with v4 against the
NVIDIA image group. Unexpected IDs, other packages and other versions remain unsuppressed by these
new statements. Obtain a rebuilt arm64 scan before adding new arm64 statements. This review makes no
host-kernel or complete-image qualification claim.

Portable data: `linux-libc-dev-2026-09-08.evidence.json` records source URLs, hashes, affected paths
and which original findings occur in the rebuilt CI report. The companion `.ci.json` records that
residual and provenance. Raw CI artifacts, source captures and the job log are retained under
`analysis/ci-artifacts/infra-34192891669-a2f62d3-vex-5048f49d/` in the parent workspace. Earlier
upstream responses, package inventories/DEBs and the original candidate patches remain under
`analysis/trivy-review/` in the isolated worktree as historical evidence; the committed files define
the active policy.
