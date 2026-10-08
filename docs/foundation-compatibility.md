# Foundation Compatibility Lock

Generated from the single workspace revision in `foundation.repos`.

| Component | Version | Workspace commit |
| --- | --- | --- |
| `robotics-runtime-contracts` | `0.19.0` | `efeac712ea512b19523ce41be40752f703fa782b` |
| `robotics-acceptance-harness` | `0.20.0` | `efeac712ea512b19523ce41be40752f703fa782b` |

The pin is bound to the source tags `harness-v0.20.0` and `contracts-v0.19.0`.
The pinned commit matches the harness tag, and its contracts source
tree is identical to the contracts tag.
This proves source identity, not completed package publication.
Verify publication separately before release adoption.
The images use a source-built package cohort from these immutable source trees.
Package source trees and project metadata are bound by this compatibility lock.
Whole wheel archive digests identify this source-built cohort.
Build dependencies remain locked.
CI checks the imported revision, workspace lock and installed image versions.
Stable release adoption remains gated on completed publication and foundation qualification.
