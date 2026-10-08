"""Compare RKNN Toolkit2 simulator output with ONNX Runtime for one ONNX model.

The model is converted for the target platform, run on the x86 simulator
(no device), and compared with the ONNX Runtime CPU provider. This qualifies
the conversion of this model and input set; it does not qualify other models
or replace execution on the NPU. Use trusted model artifacts only.
"""

from __future__ import annotations

import argparse
import json
import sys
from importlib.metadata import version
from pathlib import Path
from typing import Any

import numpy as np
import onnxruntime as ort
from google.protobuf.internal import api_implementation
from rknn.api import RKNN

SCHEMA_VERSION = "rknn-simulator-conformance.v1"
PACKAGES = (
    "rknn-toolkit2",
    "onnx",
    "onnxruntime",
    "protobuf",
    "numpy",
    "torch",
    "setuptools",
)


class SimulatorError(RuntimeError):
    """An RKNN Toolkit2 step reported failure."""


def _require_success(status: int, step: str) -> None:
    if status != 0:
        raise SimulatorError(f"RKNN {step} returned {status}")


def simulate(
    model: Path,
    inputs: list[np.ndarray],
    target_platform: str,
    dataset: Path | None,
) -> list[np.ndarray]:
    """Convert the model and run it on the simulator; quantize with a dataset."""
    rknn = RKNN(verbose=False)
    try:
        _require_success(rknn.config(target_platform=target_platform), "config")
        _require_success(rknn.load_onnx(model=str(model)), "load_onnx")
        if dataset is None:
            _require_success(rknn.build(do_quantization=False), "build")
        else:
            _require_success(
                rknn.build(do_quantization=True, dataset=str(dataset)), "build"
            )
        _require_success(rknn.init_runtime(), "init_runtime")
        outputs = rknn.inference(inputs=inputs, data_format=["nchw"] * len(inputs))
    finally:
        rknn.release()
    if outputs is None:
        raise SimulatorError("RKNN inference returned no outputs")
    return [np.asarray(output) for output in outputs]


def compare(
    expected: list[np.ndarray],
    actual: list[np.ndarray],
    rtol: float,
    atol: float,
) -> dict[str, Any]:
    """Compare simulator outputs with reference outputs element by element."""
    if len(expected) != len(actual):
        return {
            "passed": False,
            "reason": f"output count {len(actual)} differs from {len(expected)}",
        }
    outputs = []
    passed = True
    for index, (reference, simulated) in enumerate(zip(expected, actual)):
        if simulated.size != reference.size:
            passed = False
            outputs.append(
                {
                    "index": index,
                    "reference_shape": list(reference.shape),
                    "simulated_shape": list(simulated.shape),
                    "passed": False,
                }
            )
            continue
        simulated = simulated.reshape(reference.shape).astype(reference.dtype)
        error = float(np.max(np.abs(simulated - reference)))
        close = bool(np.allclose(simulated, reference, rtol=rtol, atol=atol))
        passed = passed and close
        outputs.append(
            {
                "index": index,
                "shape": list(reference.shape),
                "max_abs_error": error,
                "passed": close,
            }
        )
    return {"passed": passed, "outputs": outputs}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model", type=Path)
    parser.add_argument("inputs", nargs="+", type=Path, help="one .npy per input")
    parser.add_argument("--target-platform", default="rk3588")
    parser.add_argument(
        "--quantization-dataset",
        type=Path,
        help="build an 8-bit model from this RKNN dataset list",
    )
    parser.add_argument("--rtol", type=float, default=1e-2)
    parser.add_argument("--atol", type=float, default=1e-2)
    parser.add_argument("--report", type=Path)
    parser.add_argument(
        "--save-outputs",
        type=Path,
        help="write simulator outputs as .npy files into this directory",
    )
    args = parser.parse_args()

    arrays = [np.load(path, allow_pickle=False) for path in args.inputs]
    session = ort.InferenceSession(str(args.model), providers=["CPUExecutionProvider"])
    names = [model_input.name for model_input in session.get_inputs()]
    if len(names) != len(arrays):
        parser.error(f"model has {len(names)} inputs, received {len(arrays)}")
    expected = session.run(None, dict(zip(names, arrays)))
    try:
        actual = simulate(
            args.model, arrays, args.target_platform, args.quantization_dataset
        )
        result = compare(expected, actual, args.rtol, args.atol)
    except SimulatorError as error:
        actual = []
        result = {"passed": False, "reason": str(error)}

    if args.save_outputs is not None:
        args.save_outputs.mkdir(parents=True, exist_ok=True)
        for index, output in enumerate(actual):
            np.save(args.save_outputs / f"output_{index}.npy", output)

    report = {
        "schema_version": SCHEMA_VERSION,
        "status": "passed" if result["passed"] else "failed",
        "model": args.model.name,
        "target_platform": args.target_platform,
        "quantized": args.quantization_dataset is not None,
        "tolerances": {"relative": args.rtol, "absolute": args.atol},
        "packages": {name: version(name) for name in PACKAGES},
        "protobuf_backend": api_implementation.Type(),
        **{key: value for key, value in result.items() if key != "passed"},
    }
    serialized = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.report is not None:
        args.report.write_text(serialized, encoding="utf-8")
    sys.stdout.write(serialized)
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
