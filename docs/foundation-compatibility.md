# Foundation Compatibility Lock

Generated from the single workspace revision in `foundation.repos`.

| Component | Version | Workspace commit |
| --- | --- | --- |
| `robotics-runtime-contracts` | `0.18.3` | `ecfb0446fddad70e8ab1094694dddacfeb496d53` |
| `robotics-acceptance-harness` | `0.19.2` | `ecfb0446fddad70e8ab1094694dddacfeb496d53` |

The pin is bound to the source tags `harness-v0.19.2` and `contracts-v0.18.3`.
The pinned commit matches the harness tag, and its contracts source
tree is identical to the contracts tag.
This proves source identity, not completed package publication.
Verify publication separately before release adoption.
Both packages are built from this source with locked build dependencies.
CI checks the imported revision, workspace lock and installed image versions.
Stable release adoption remains gated on completed publication and foundation qualification.
