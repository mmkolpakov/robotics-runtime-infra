# Product node provisioning

These roles configure explicitly enrolled Ubuntu 24.04 product VM/edge nodes
over SSH. They do not manage the developer workstation, shared infrastructure,
Kubernetes nodes, robot control, CAN links, CAN transmission, device permissions,
or phc2sys. No inventory is selected by default. The example uses an invalid
product hostname and deliberately unusable package versions.

Install the pinned controller dependencies from `requirements.lock` into a
project Python 3.12 environment. Only `ansible.builtin` is used;
`requirements.yml` intentionally contains no external roles or collections.
The maintained published pins are ansible-core 2.21.4 and ansible-lint 26.9.0:
[core publication](https://pypi.org/project/ansible-core/2.21.4/),
[lint publication](https://pypi.org/project/ansible-lint/26.9.0/),
[maintenance matrix](https://docs.ansible.com/projects/ansible-core/devel/reference_appendices/release_and_maintenance.html).

Run from this directory with a separately reviewed inventory and a one-node
limit. Copy `inventories/example.yml` outside version control and replace all
examples. Keep site credentials outside inventory and use normal SSH/Vault
facilities. Supply exact package versions from the approved product repository;
the play neither changes apt sources nor updates the package index.

```sh
ansible-playbook -i /absolute/path/product-inventory.yml product-nodes.yml --syntax-check
ansible-playbook -i /absolute/path/product-inventory.yml product-nodes.yml --check --diff --limit product_node_01
# On an independently authorized product node:
ansible-playbook -i /absolute/path/product-inventory.yml product-nodes.yml --limit product_node_01
```

`robotics_node_enrolled: true` and a nonempty `robotics_node_features` list are
required. Supported features and additional site variables:

- `time_chrony`: `robotics_node_time_evidence_dir`,
  `robotics_node_chrony_sources` (server/pool lines, optional iburst), and
  `robotics_node_chrony_existing_config_reviewed: true`. Review existing source
  configuration and every chronyc consumer before relocating its command socket
  to `/run/robotics-time/chronyd.sock`. The role keeps the canonical UDP command
  port disabled and requires the main config to load `/etc/chrony/conf.d`.
- `time_ptp`: the evidence directory, `robotics_node_ptp_interface`,
  integer `robotics_node_ptp_domain` (0–127),
  `robotics_node_ptp_time_source: external-grandmaster`, and
  `robotics_node_ptp_existing_service_reviewed: true`. A site-owned
  `ptp4l.service` must already exist. Its reviewed override selects the canonical
  UDPv4/E2E hardware-timestamp config and client mode; other daemon confinement
  stays in the existing unit. phc2sys, grandmaster identity and actual hardware
  timestamp/UTC offset qualification remain site acceptance requirements.
- `can_observation`: `robotics_node_can_interfaces` records with `name`,
  positive integer `bitrate`, and exact `device_identity` (the resolved
  `/sys/class/net/INTERFACE/device` path). Require
  `robotics_node_can_network_ready: true` after creating the existing reviewed
  internal Compose network, `172.30.247.0/28`, with gateway
  `172.30.247.1:28700`. The role observes the already-up CAN link and verifies
  its bitrate/identity; it never brings it up or changes bitrate/termination.
  The unchanged gateway unit retains its empty capabilities, closed devices,
  cgroup-BPF IP allow-list and fixed TCP port.
- `physical_attach_permissions`: separate `robotics_node_authorization_dir`
  and `robotics_node_nonce_dir` under `/var/lib/robotics`, plus reviewed
  `robotics_node_physical_device_identities` under stable serial by-id/by-path
  names. Only directory permissions are managed: UID/GID 10002, authorization
  mode 0755 and private nonce mode 0700. No device is opened or mapped.

Time dependencies: exact bash/coreutils/jq/chrony package versions; PTP adds
linuxptp. CAN adds can-utils/iproute2. The existing runtime profile qualifies
Chrony 4.5, linuxptp 4.0, systemd 255+, and Ubuntu can-utils from its pinned
snapshot. Select that reviewed package cohort, not arbitrary newer packages.
Product approval and operational verification are still necessary; a package
pin does not establish hardware qualification.

The roles copy samplers, normalizer, tmpfiles, sampler units, Chrony socket
fragment and CAN gateway directly from their existing repository assets.
Only site source/domain/interface settings are rendered. Changing feature
selection does not automatically decommission previously installed services;
decommissioning requires a separate reviewed site action.

## Checks and remaining acceptance

From the repository root, run `scripts/ci/check-product-ansible.sh` with Docker.
For the declared rootless Podman environment, set `ROBOTICS_IMAGE_ENGINE=podman`.
It builds a project container from pinned Ubuntu/uv images and the Ubuntu
20260930 snapshot, installs the hash-locked controller dependencies, then
runs without networking. Its small CHOWN/FOWNER capability set permits real
file-owner tests inside its isolated filesystem. It does not expose host
devices, a service manager, a Podman socket, or a writable repository.

The checks run syntax validation, production-profile ansible-lint, explicit-site
negative assertions, byte identity against canonical assets, site template
checks, owner/mode and final/ancestor nonce-symlink checks, and two real copy/template/file passes
followed by check/diff. The second file pass must report zero changes. Production entrypoint
guards reject local connections and nonempty staging roots.

This fixture intentionally imports only validation/file tasks into a disposable
container directory. It does not prove apt convergence, systemd daemon/timer
idempotence, Chrony/PTP synchronization, hardware timestamps, cgroup-BPF filtering,
CAN transport, physical authorization or a physical acceptance verdict. Before
supporting a site, apply twice on its independently authorized product target,
require the second full apply to have zero changes, and collect the existing
runtime preflight/observation evidence during the actual observation window.
Check mode alone is not service or hardware acceptance.
