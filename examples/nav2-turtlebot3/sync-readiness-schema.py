"""Copy the pinned public scenario's ROS graph type into this local extension."""

import argparse
import copy
import json
from importlib.metadata import version
from pathlib import Path

from robotics_runtime_contracts import load_schema, schema_registry

ROOT = Path(__file__).parent


def definitions():
    if version("robotics-runtime-contracts") != "0.21.1":
        raise ValueError(
            "readiness schema generation requires the pinned contracts 0.21.1"
        )
    public = load_schema("acceptance-scenario.v1")
    resolver = schema_registry().resolver(base_uri=public["$id"])
    declared = resolver.lookup(public["properties"]["expected_ros_graph"]["$ref"])
    graph = declared.resolver.lookup(declared.contents["$ref"])
    result = {"expectedRosGraph": copy.deepcopy(graph.contents)}
    resolved = {}
    for array, name in (
        ("topics", "topicExpectation"),
        ("services", "graphEndpoint"),
        ("actions", "graphEndpoint"),
        ("lifecycle_nodes", "lifecycleNode"),
    ):
        reference = graph.contents["properties"][array]["items"]["$ref"]
        item = graph.resolver.lookup(reference)
        if name in result and result[name] != item.contents:
            raise ValueError("the pinned graph endpoint types differ")
        result[name] = copy.deepcopy(item.contents)
        resolved[name] = item

    # This is the pinned graph type's seven leaf-reference locations, rather
    # than a general schema bundler. Resolve only references supplied by the
    # public scenario type; extension schemas require their copies to be local.
    for owner, field, name in (
        ("topicExpectation", "name", "rosName"),
        ("topicExpectation", "type", "rosMessageType"),
        ("topicExpectation", "first_message_timeout_sec", "positiveSeconds"),
        ("graphEndpoint", "name", "rosName"),
        ("graphEndpoint", "type", "rosType"),
        ("lifecycleNode", "name", "rosName"),
        ("lifecycleNode", "timeout_sec", "positiveSeconds"),
    ):
        reference = resolved[owner].contents["properties"][field]["$ref"]
        leaf = resolved[owner].resolver.lookup(reference).contents
        if name in result and result[name] != leaf:
            raise ValueError("the pinned graph leaf types differ")
        result[name] = copy.deepcopy(leaf)
        result[owner]["properties"][field]["$ref"] = f"#/$defs/{name}"
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    path = ROOT / "nav2.schema.json"
    document = json.loads(path.read_bytes())
    expected = definitions()
    if arguments.check:
        if document.get("$defs") != expected:
            parser.exit(
                1, "consumer readiness definitions differ from the pinned SDK\n"
            )
    else:
        document["$defs"] = expected
        document["properties"]["readiness"]["properties"]["graph"] = {
            "$ref": "#/$defs/expectedRosGraph"
        }
        path.write_text(json.dumps(document, indent=2) + "\n")


if __name__ == "__main__":
    main()
