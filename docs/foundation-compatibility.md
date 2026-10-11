# Foundation Compatibility Lock

Generated from the common workspace pin in `foundation.repos` and each package release tag.

| Component | Version | Build input commit |
| --- | --- | --- |
| `robotics-runtime-contracts` | `0.21.1` | `a6fd70f73b6c7c4f2b70b449e5dedeefb96d46fa` |
| `robotics-acceptance-harness` | `0.22.1` | `c50215ee23e0e57ada671205ae70df7496c71855` |

The pin is bound to the source tags `harness-v0.22.1` and `contracts-v0.21.1`.
Each complete build input is bound to its own tag and commit.
The common workspace's contracts `src` tree and `pyproject.toml`
match the contracts tag; its documentation is not used to build contracts.
Tag/source binding is separate from publication and image admission.
The images build each package from its complete immutable Git context.
The named Git context ref and checksum bind every supplied input byte.
The build helper checks lock/project metadata; its uv.lock hash alone
does not authenticate an arbitrary supplied source directory.
Generated whole-wheel hashes identify each candidate build output.
Compare them with authenticated published assets when asserting
release-wheel equality.
Build dependencies remain locked.
CI checks the imported revision, workspace lock and installed image versions.
Stable release adoption remains gated on completed publication and foundation qualification.
