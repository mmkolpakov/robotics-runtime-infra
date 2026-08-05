from __future__ import annotations

import hashlib
import json
import math
import os
import time
from pathlib import Path
from typing import Final

import numpy as np
import onnxruntime as ort
import rclpy
from diagnostic_msgs.msg import DiagnosticArray, DiagnosticStatus, KeyValue
from onnxruntime.datasets import get_example
from opentelemetry import metrics, trace
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from rclpy.node import Node
from robotics_inference_conformance import profiled_providers, provider_options
from sensor_msgs.msg import Image, LaserScan

SERVICE_NAME: Final = "robotics-sensor-inference-probe"


def required_environment(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"{name} is required")
    return value


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    index = min(len(ordered) - 1, math.ceil(len(ordered) * fraction) - 1)
    return ordered[index]


class SensorInferenceProbe(Node):
    def __init__(self) -> None:
        super().__init__("sensor_inference_probe")
        self.expected_provider = required_environment("ROBOTICS_EXPECTED_PROVIDER")
        self.sensor_type = os.environ.get("ROBOTICS_SENSOR_TYPE", "image")
        self.sensor_topic = required_environment("ROBOTICS_SENSOR_TOPIC")
        self.target_frames = int(os.environ.get("ROBOTICS_PROBE_FRAMES", "30"))
        if self.target_frames < 1:
            raise RuntimeError("ROBOTICS_PROBE_FRAMES must be positive")
        self.report_path = Path(
            os.environ.get(
                "ROBOTICS_PROBE_REPORT",
                "/reports/sensor-inference.json",
            )
        )
        self.attributes = {
            "channel": self.sensor_topic,
            "provider": self.expected_provider,
            "sensor.type": self.sensor_type,
        }
        self.received = 0
        self.inferred = 0
        self.latencies_ms: list[float] = []
        self.maximum_absolute_error = 0.0
        self.numerical_parity = True
        self.samples: list[np.ndarray] = []
        self.started_ns = time.monotonic_ns()
        self.done = False

        if hasattr(ort, "preload_dlls") and self.expected_provider in {
            "CUDAExecutionProvider",
            "TensorrtExecutionProvider",
        }:
            ort.preload_dlls()

        options = ort.SessionOptions()
        if self.expected_provider != "CPUExecutionProvider":
            options.add_session_config_entry("session.disable_cpu_ep_fallback", "1")
        options.enable_profiling = True
        options.profile_file_prefix = "/tmp/robotics-sensor-inference-profile"
        self.provider_options, self.provider_options_sha256 = provider_options()
        self.model_path = Path(get_example("sigmoid.onnx"))
        self.model_artifact_sha256 = hashlib.sha256(
            self.model_path.read_bytes()
        ).hexdigest()
        self.session = ort.InferenceSession(
            self.model_path,
            sess_options=options,
            providers=[self.expected_provider],
            provider_options=[self.provider_options],
        )
        self.session.disable_fallback()
        if self.session.get_providers()[0] != self.expected_provider:
            raise RuntimeError(
                f"expected {self.expected_provider}, got {self.session.get_providers()}"
            )

        self.model_input = self.session.get_inputs()[0]
        self.reference_session = ort.InferenceSession(
            self.model_path,
            providers=["CPUExecutionProvider"],
        )
        self.reference_input = self.reference_session.get_inputs()[0]
        self.relative_tolerance = float(
            os.environ.get("ROBOTICS_PROVIDER_RTOL", "1e-5")
        )
        self.absolute_tolerance = float(
            os.environ.get("ROBOTICS_PROVIDER_ATOL", "1e-6")
        )
        self.input_shape = [
            dimension if isinstance(dimension, int) else 2
            for dimension in self.model_input.shape
        ]
        self.input_size = int(np.prod(self.input_shape))

        meter = metrics.get_meter(SERVICE_NAME)
        self.received_counter = meter.create_counter(
            "robotics.sensor.frames",
            unit="{frame}",
        )
        self.inference_counter = meter.create_counter(
            "robotics.inference.executions",
            unit="{inference}",
        )
        self.latency_histogram = meter.create_histogram(
            "robotics.inference.latency",
            unit="ms",
        )
        self.tracer = trace.get_tracer(SERVICE_NAME)
        self.diagnostics = self.create_publisher(
            DiagnosticArray,
            "/robotics/qualification/inference",
            10,
        )

        if self.sensor_type == "image":
            self.subscription = self.create_subscription(
                Image,
                self.sensor_topic,
                self.on_image,
                10,
            )
        elif self.sensor_type == "laser_scan":
            self.subscription = self.create_subscription(
                LaserScan,
                self.sensor_topic,
                self.on_laser_scan,
                10,
            )
        else:
            raise RuntimeError(f"unsupported sensor type: {self.sensor_type}")

    def on_image(self, message: Image) -> None:
        values = np.frombuffer(message.data, dtype=np.uint8).astype(np.float32)
        self.process(values / 255.0)

    def on_laser_scan(self, message: LaserScan) -> None:
        values = np.asarray(message.ranges, dtype=np.float32)
        finite = values[np.isfinite(values)]
        replacement = float(finite.max()) if finite.size else 0.0
        self.process(np.nan_to_num(values, nan=0.0, posinf=replacement, neginf=0.0))

    def process(self, values: np.ndarray) -> None:
        if self.done or values.size == 0:
            return
        self.received += 1
        self.received_counter.add(1, self.attributes)
        tensor = np.resize(values, self.input_size).reshape(self.input_shape)
        self.samples.append(tensor.copy())

        started_ns = time.perf_counter_ns()
        with self.tracer.start_as_current_span(
            "robotics.sensor.inference",
            attributes=self.attributes,
        ):
            outputs = self.session.run(None, {self.model_input.name: tensor})
        latency_ms = (time.perf_counter_ns() - started_ns) / 1_000_000
        if not outputs or not np.isfinite(outputs[0]).all():
            raise RuntimeError("inference returned no finite output")
        reference_outputs = self.reference_session.run(
            None,
            {self.reference_input.name: tensor},
        )
        absolute_error = float(np.max(np.abs(outputs[0] - reference_outputs[0])))
        self.maximum_absolute_error = max(self.maximum_absolute_error, absolute_error)
        self.numerical_parity = self.numerical_parity and bool(
            np.allclose(
                outputs[0],
                reference_outputs[0],
                rtol=self.relative_tolerance,
                atol=self.absolute_tolerance,
            )
        )

        self.inferred += 1
        self.latencies_ms.append(latency_ms)
        self.inference_counter.add(1, self.attributes)
        self.latency_histogram.record(latency_ms, self.attributes)
        self.diagnostics.publish(
            DiagnosticArray(
                status=[
                    DiagnosticStatus(
                        level=DiagnosticStatus.OK,
                        name="sensor_inference",
                        message="provider execution completed",
                        values=[
                            KeyValue(key="provider", value=self.expected_provider),
                            KeyValue(key="sensor_topic", value=self.sensor_topic),
                        ],
                    )
                ]
            )
        )
        if self.inferred >= self.target_frames:
            self.done = True

    def write_report(self) -> None:
        duration_sec = (time.monotonic_ns() - self.started_ns) / 1_000_000_000
        profile_path = Path(self.session.end_profiling())
        executed_providers = profiled_providers(profile_path)
        profile_path.unlink(missing_ok=True)
        fallback_providers = [
            provider
            for provider in executed_providers
            if provider != self.expected_provider
        ]
        passed = (
            self.done
            and executed_providers == [self.expected_provider]
            and self.numerical_parity
        )
        self.report_path.parent.mkdir(parents=True, exist_ok=True)
        sample_dataset_path = self.report_path.with_name("sample-inputs.npy")
        np.save(sample_dataset_path, np.stack(self.samples), allow_pickle=False)
        sample_dataset_sha256 = hashlib.sha256(
            sample_dataset_path.read_bytes()
        ).hexdigest()
        report = {
            "schema_version": "sensor-inference-observation.v1",
            "status": "passed" if passed else "failed",
            "provider": self.expected_provider,
            "runtime_version": ort.__version__,
            "session_providers": self.session.get_providers(),
            "executed_providers": executed_providers,
            "fallback_count": len(fallback_providers),
            "fallback_providers": fallback_providers,
            "provider_options": self.provider_options,
            "provider_options_sha256": self.provider_options_sha256,
            "model_path": str(self.model_path),
            "model_artifact_sha256": self.model_artifact_sha256,
            "sample_dataset_path": str(sample_dataset_path),
            "sample_dataset_sha256": sample_dataset_sha256,
            "sensor_type": self.sensor_type,
            "sensor_topic": self.sensor_topic,
            "received_frames": self.received,
            "inference_count": self.inferred,
            "duration_sec": duration_sec,
            "observed_rate_hz": self.inferred / duration_sec,
            "latency_ms": {
                "p50": percentile(self.latencies_ms, 0.50),
                "p95": percentile(self.latencies_ms, 0.95),
                "max": max(self.latencies_ms),
            },
            "numerical_parity": self.numerical_parity,
            "maximum_absolute_error": self.maximum_absolute_error,
            "tolerances": {
                "relative": self.relative_tolerance,
                "absolute": self.absolute_tolerance,
            },
        }
        self.report_path.write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )


def configure_telemetry() -> tuple[MeterProvider, TracerProvider]:
    resource = Resource.create(
        {
            "service.name": SERVICE_NAME,
            "service.namespace": "robotics-runtime",
            "run.id": required_environment("ROBOTICS_RUN_ID"),
            "domain.id": required_environment("ROBOTICS_DOMAIN_ID"),
        }
    )
    endpoint = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:4318")
    meter_provider = MeterProvider(
        resource=resource,
        metric_readers=[
            PeriodicExportingMetricReader(
                OTLPMetricExporter(endpoint=f"{endpoint}/v1/metrics"),
                export_interval_millis=1_000,
            )
        ],
    )
    tracer_provider = TracerProvider(resource=resource)
    tracer_provider.add_span_processor(
        BatchSpanProcessor(OTLPSpanExporter(endpoint=f"{endpoint}/v1/traces"))
    )
    metrics.set_meter_provider(meter_provider)
    trace.set_tracer_provider(tracer_provider)
    return meter_provider, tracer_provider


def main() -> None:
    meter_provider, tracer_provider = configure_telemetry()
    rclpy.init()
    node: SensorInferenceProbe | None = None
    try:
        node = SensorInferenceProbe()
        timeout_sec = float(os.environ.get("ROBOTICS_PROBE_TIMEOUT_SEC", "120"))
        deadline = time.monotonic() + timeout_sec
        while rclpy.ok() and not node.done and time.monotonic() < deadline:
            rclpy.spin_once(node, timeout_sec=0.5)
        if not node.done:
            raise RuntimeError(
                f"received {node.inferred}/{node.target_frames} frames before timeout"
            )
        node.write_report()
    finally:
        if node is not None:
            node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()
        meter_provider.force_flush(timeout_millis=10_000)
        tracer_provider.force_flush(timeout_millis=10_000)
        meter_provider.shutdown(timeout_millis=10_000)
        tracer_provider.shutdown()


if __name__ == "__main__":
    main()
