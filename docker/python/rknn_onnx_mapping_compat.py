"""Expose the onnx.mapping tables that RKNN Toolkit2 2.3.2 still reads.

onnx 1.19 removed onnx.mapping. The toolkit reads only TENSOR_TYPE_TO_NP_TYPE
and NP_TYPE_TO_TENSOR_TYPE, so both are rebuilt with the onnx 1.18 values. A
.pth file imports this module in the RKNN converter environment only.
"""

from __future__ import annotations

import sys
import types

import numpy as np
import onnx
from onnx import TensorProto

_NATIVE = {
    TensorProto.FLOAT: "float32",
    TensorProto.UINT8: "uint8",
    TensorProto.INT8: "int8",
    TensorProto.UINT16: "uint16",
    TensorProto.INT16: "int16",
    TensorProto.INT32: "int32",
    TensorProto.INT64: "int64",
    TensorProto.BOOL: "bool",
    TensorProto.FLOAT16: "float16",
    TensorProto.DOUBLE: "float64",
    TensorProto.COMPLEX64: "complex64",
    TensorProto.COMPLEX128: "complex128",
    TensorProto.UINT32: "uint32",
    TensorProto.UINT64: "uint64",
    TensorProto.STRING: "object",
}

# onnx 1.18 widened types without a NumPy dtype and kept them out of the
# reverse table.
_WIDENED = {
    TensorProto.BFLOAT16: "float32",
    TensorProto.FLOAT8E4M3FN: "float32",
    TensorProto.FLOAT8E4M3FNUZ: "float32",
    TensorProto.FLOAT8E5M2: "float32",
    TensorProto.FLOAT8E5M2FNUZ: "float32",
    TensorProto.UINT4: "uint8",
    TensorProto.INT4: "int8",
    TensorProto.FLOAT4E2M1: "float32",
}


def _install() -> None:
    if hasattr(onnx, "mapping"):
        return
    module = types.ModuleType("onnx.mapping", __doc__)
    module.TENSOR_TYPE_TO_NP_TYPE = {
        int(tensor_type): np.dtype(name)
        for tensor_type, name in {**_NATIVE, **_WIDENED}.items()
    }
    module.NP_TYPE_TO_TENSOR_TYPE = {
        np.dtype(name): int(tensor_type) for tensor_type, name in _NATIVE.items()
    }
    onnx.mapping = module
    sys.modules["onnx.mapping"] = module


_install()
