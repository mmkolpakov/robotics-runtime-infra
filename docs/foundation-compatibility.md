# Foundation Compatibility Lock

Generated from the single workspace revision in `foundation.repos`.

| Component | Version | Workspace commit |
| --- | --- | --- |
| `robotics-runtime-contracts` | `0.18.1` | `7ed80b9da1b26b84fe8ee40b7f79c525ed6bce74` |
| `robotics-acceptance-harness` | `0.19.0` | `7ed80b9da1b26b84fe8ee40b7f79c525ed6bce74` |

The pin is bound to the source tags `harness-v0.19.0` and `contracts-v0.18.1`.
The pinned commit matches the harness tag, and its contracts source
tree is identical to the contracts tag.
This proves source identity, not completed package publication.
Verify publication separately before release adoption.
Both packages are built from this source with locked build dependencies.
CI checks the imported revision, workspace lock and installed image versions.
Stable release adoption remains gated on completed publication and foundation qualification.
