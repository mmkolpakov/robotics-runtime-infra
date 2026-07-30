from setuptools import find_packages, setup

PACKAGE_NAME = "robotics_observability"

setup(
    name=PACKAGE_NAME,
    version="0.8.0",
    packages=find_packages(exclude=("test",)),
    data_files=[
        ("share/ament_index/resource_index/packages", [f"resource/{PACKAGE_NAME}"]),
        (f"share/{PACKAGE_NAME}", ["package.xml"]),
    ],
    install_requires=[
        "opentelemetry-api",
        "opentelemetry-exporter-otlp-proto-http",
        "opentelemetry-sdk",
        "setuptools",
    ],
    extras_require={"test": ["pytest"]},
    entry_points={
        "console_scripts": [
            "runtime_metrics = robotics_observability.runtime_metrics:main",
        ],
    },
    zip_safe=True,
    maintainer="mmkolpakov",
    maintainer_email="184955981+mmkolpakov@users.noreply.github.com",
    description="OpenTelemetry propagation and runtime measurements for ROS 2.",
    license="MIT",
)
