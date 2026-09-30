"""Compare the RKNN Toolkit2 simulator with ONNX Runtime on the retained example model."""

import numpy as np
import onnx
import onnxruntime as ort
from rknn.api import RKNN

MODEL = "concat_block.onnx"
RELATIVE_TOLERANCE = 1e-2

inputs = [np.load(f"concat_block_input_{index}.npy") for index in range(2)]
names = [value.name for value in onnx.load(MODEL).graph.input]
session = ort.InferenceSession(MODEL, providers=["CPUExecutionProvider"])
expected = session.run(None, dict(zip(names, inputs, strict=True)))

rknn = RKNN(verbose=False)
rknn.config(target_platform="rk3588")
if rknn.load_onnx(MODEL) != 0 or rknn.build(do_quantization=False) != 0:
    raise SystemExit("RKNN float conversion failed")
if rknn.init_runtime() != 0:
    raise SystemExit("RKNN simulator did not start")
actual = rknn.inference(inputs=inputs, data_format="nchw")
rknn.release()

if len(actual) != len(expected):
    raise SystemExit(
        f"simulator returned {len(actual)} outputs, expected {len(expected)}"
    )
for index, (got, want) in enumerate(zip(actual, expected, strict=True)):
    got = np.asarray(got, dtype=np.float32).reshape(want.shape)
    error = float(np.max(np.abs(got - want)))
    scale = float(np.max(np.abs(want))) or 1.0
    print(f"output {index}: max abs error {error:.3g}, max |reference| {scale:.3g}")
    if error > RELATIVE_TOLERANCE * scale:
        raise SystemExit(f"output {index} differs from ONNX Runtime")
