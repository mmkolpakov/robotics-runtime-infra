import argparse
import json
import time


class JsonParser(argparse.ArgumentParser):
    def error(self, message):
        raise ValueError(message)


def query(args, report):
    import rclpy
    from simulation_interfaces.msg import Result
    from simulation_interfaces.srv import GetEntities

    deadline = time.monotonic() + args.timeout_sec
    node = None
    rclpy.init(args=[])
    try:
        node = rclpy.create_node("neutral_robot_entity_probe")
        client = node.create_client(GetEntities, report["service"])
        if not client.wait_for_service(
            timeout_sec=max(0.0, deadline - time.monotonic())
        ):
            raise RuntimeError("GetEntities service discovery timed out")
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                if report["result"] is None:
                    raise RuntimeError("GetEntities deadline expired before a response")
                report["status"] = "entity_absent"
                return 70
            future = client.call_async(GetEntities.Request())
            rclpy.spin_until_future_complete(node, future, timeout_sec=remaining)
            if not future.done() or future.result() is None:
                raise RuntimeError("GetEntities service call timed out")
            response = future.result()
            if not isinstance(response, GetEntities.Response):
                raise RuntimeError("GetEntities returned an invalid response")
            report["result"] = {
                "result": response.result.result,
                "error_message": response.result.error_message,
            }
            report["entities"] = list(response.entities)
            if response.result.result != Result.RESULT_OK:
                raise RuntimeError("GetEntities returned a non-OK result")
            report["exists"] = args.entity in response.entities
            if report["exists"] == (args.expect == "present"):
                report["status"] = "passed"
                return 0
            if args.expect == "absent":
                report["status"] = "entity_present"
                return 70
            time.sleep(min(0.1, max(0.0, deadline - time.monotonic())))
    finally:
        if node is not None:
            node.destroy_node()
        rclpy.try_shutdown()


def main():
    report = {
        "service": "/simulator/get_entities",
        "entity": "neutral_robot",
        "expected": "present",
        "exists": None,
        "entities": [],
        "result": None,
        "status": "service_failed",
    }
    code = 69
    try:
        parser = JsonParser(
            description="Check a native simulator entity by exact name."
        )
        parser.add_argument("--entity", default="neutral_robot")
        parser.add_argument(
            "--expect", choices=("present", "absent"), default="present"
        )
        parser.add_argument("--timeout-sec", type=float, default=15.0)
        args = parser.parse_args()
        report.update(entity=args.entity, expected=args.expect)
        if not args.entity or not 0.0 < args.timeout_sec <= 90.0:
            raise ValueError("entity must be nonempty and timeout must be in (0, 90]")
        code = query(args, report)
    except (Exception, KeyboardInterrupt) as error:
        report["status"] = "service_failed"
        report["error"] = str(error) or type(error).__name__
    print(json.dumps(report, sort_keys=True, allow_nan=False))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
