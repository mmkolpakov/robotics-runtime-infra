# Foundation Compatibility Lock

Generated from the single workspace revision in `foundation.repos`.

| Component | Version | Workspace commit |
| --- | --- | --- |
| `robotics-runtime-contracts` | `0.18.2` | `dc02c62897372514537cf241f06dc71b9f960c44` |
| `robotics-acceptance-harness` | `0.19.1` | `dc02c62897372514537cf241f06dc71b9f960c44` |

The pin is bound to the source tags `harness-v0.19.1` and `contracts-v0.18.2`.
The pinned commit matches the harness tag, and its contracts source
tree is identical to the contracts tag.
This proves source identity, not completed package publication.
Verify publication separately before release adoption.
Both packages are built from this source with locked build dependencies.
CI checks the imported revision, workspace lock and installed image versions.
Stable release adoption remains gated on completed publication and foundation qualification.
