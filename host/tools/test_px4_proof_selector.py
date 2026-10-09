from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "px4_verifier", Path(__file__).with_name("verify-px4-evidence.py")
)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ProofSelection(unittest.TestCase):
    def test_explicit_current_directory_cannot_fall_back_to_an_old_success(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            parent = root / "artifacts/px4"
            old = parent / "native-old"
            current = parent / "native-current"
            old.mkdir(parents=True)
            current.mkdir()
            (old / "run-completion.json").write_text("{}")
            self.assertRaises(ValueError, MODULE.select_proof, root, current)
            (current / "run-completion.json").write_text("{}")
            self.assertEqual(MODULE.select_proof(root, current), current)
            self.assertRaises(
                ValueError, MODULE.select_proof, root, Path("native-current")
            )

    def test_external_or_aliased_proof_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            proof = root / "artifacts/px4/native-current"
            proof.mkdir(parents=True)
            (proof / "run-completion.json").write_text("{}")
            alias = proof.parent / "native-link"
            alias.symlink_to(proof, target_is_directory=True)
            self.assertRaises(ValueError, MODULE.select_proof, root, alias)
            outside = root / "outside/native-other"
            outside.mkdir(parents=True)
            (outside / "run-completion.json").write_text("{}")
            self.assertRaises(ValueError, MODULE.select_proof, root, outside)
            completion = proof / "run-completion.json"
            completion.unlink()
            completion.symlink_to(outside / "run-completion.json")
            self.assertRaises(ValueError, MODULE.select_proof, root, proof)


if __name__ == "__main__":
    unittest.main()
