from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
from typing import Any

import numpy as np
import onnxruntime as ort
import pytest
from onnxruntime.datasets import get_example


EXPECTED_PROVIDER = os.environ.get("ROBOTICS_EXPECTED_PROVIDER", "CPUExecutionProvider")
REPORT_PATH = Path(
    os.environ.get("ROBOTICS_PROVIDER_REPORT", "/reports/provider-conformance.json")
)
RTOL = float(os.environ.get("ROBOTICS_PROVIDER_RTOL", "1e-5"))
ATOL = float(os.environ.get("ROBOTICS_PROVIDER_ATOL", "1e-6"))


def _write_report(**facts: Any) -> None:
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    report = {
        "schema_version": "provider-conformance.v1",
        "runtime_family": "onnxruntime",
        "runtime_version": ort.__version__,
        "expected_provider": EXPECTED_PROVIDER,
        **facts,
    }
    REPORT_PATH.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def _exception_chain(error: BaseException) -> list[dict[str, str]]:
    chain: list[dict[str, str]] = []
    seen: set[int] = set()
    current: BaseException | None = error
    while current is not None and id(current) not in seen:
        seen.add(id(current))
        chain.append(
            {
                "type": type(current).__name__,
                "message": str(current),
            }
        )
        current = current.__cause__ or current.__context__
    return chain


def _profiled_providers(profile_path: Path) -> list[str]:
    events = json.loads(profile_path.read_text(encoding="utf-8"))
    return sorted(
        {
            str(event["args"]["provider"])
            for event in events
            if isinstance(event, dict)
            and isinstance(event.get("args"), dict)
            and event["args"].get("provider")
        }
    )


def test_provider_executes_canonical_tensor_without_fallback() -> None:
    if hasattr(ort, "preload_dlls") and EXPECTED_PROVIDER in {
        "CUDAExecutionProvider",
        "TensorrtExecutionProvider",
    }:
        ort.preload_dlls(directory="")
    available = ort.get_available_providers()
    if EXPECTED_PROVIDER not in available:
        _write_report(
            status="failed",
            reason="expected_provider_unavailable",
            available_providers=available,
            fallback_count=0,
        )
        pytest.fail(
            f"{EXPECTED_PROVIDER} is unavailable; available providers: {available}"
        )

    options = ort.SessionOptions()
    if EXPECTED_PROVIDER != "CPUExecutionProvider":
        options.add_session_config_entry("session.disable_cpu_ep_fallback", "1")
    options.enable_profiling = True
    options.profile_file_prefix = "/tmp/robotics-provider-profile"
    provider_options = json.loads(
        os.environ.get("ROBOTICS_PROVIDER_OPTIONS", "") or "{}"
    )

    try:
        session = ort.InferenceSession(
            get_example("sigmoid.onnx"),
            sess_options=options,
            providers=[EXPECTED_PROVIDER],
            provider_options=[provider_options],
        )
    except Exception as error:
        _write_report(
            status="failed",
            reason="session_initialization_failed",
            available_providers=available,
            provider_options=provider_options,
            fallback_count=0,
            error=f"{type(error).__name__}: {error}",
            error_chain=_exception_chain(error),
        )
        raise
    session_providers = session.get_providers()
    model_input = session.get_inputs()[0]
    shape = [
        dimension if isinstance(dimension, int) else 2
        for dimension in model_input.shape
    ]
    values = np.linspace(-4.0, 4.0, num=int(np.prod(shape)), dtype=np.float32)
    values = values.reshape(shape)
    outputs = session.run(None, {model_input.name: values})
    profile_path = Path(session.end_profiling())
    executed_providers = _profiled_providers(profile_path)
    profile_path.unlink(missing_ok=True)

    expected = 1.0 / (1.0 + np.exp(-values))
    numerical_error: str | None = None
    try:
        np.testing.assert_allclose(outputs[0], expected, rtol=RTOL, atol=ATOL)
    except AssertionError as error:
        numerical_error = str(error)

    fallback_providers = [
        provider for provider in executed_providers if provider != EXPECTED_PROVIDER
    ]
    status = (
        "passed"
        if session_providers[0] == EXPECTED_PROVIDER
        and executed_providers == [EXPECTED_PROVIDER]
        and numerical_error is None
        else "failed"
    )
    _write_report(
        status=status,
        available_providers=available,
        session_providers=session_providers,
        executed_providers=executed_providers,
        fallback_count=len(fallback_providers),
        fallback_providers=fallback_providers,
        provider_options=provider_options,
        tolerances={"relative": RTOL, "absolute": ATOL},
        output={
            "dtype": str(outputs[0].dtype),
            "shape": list(outputs[0].shape),
            "sha256": hashlib.sha256(outputs[0].tobytes()).hexdigest(),
        },
        numerical_error=numerical_error,
    )

    assert session_providers[0] == EXPECTED_PROVIDER
    assert executed_providers == [EXPECTED_PROVIDER]
    assert numerical_error is None
