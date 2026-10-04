#!/usr/bin/env python3
"""Finite native GI API qualification; no host frame forwarding."""

import json
import gi

gi.require_version("Gst", "1.0")
from gi.repository import Gst  # noqa: E402 - GI version is selected before importing Gst

Gst.init(None)
reports = []
for description in (
    "videotestsrc num-buffers=2 ! fakesink",
    "filesrc location=/nonexistent/c12-input ! fakesink",
):
    pipeline = Gst.parse_launch(description)
    try:
        change = pipeline.set_state(Gst.State.PLAYING)
        state = pipeline.get_state(5 * Gst.SECOND)
        message = pipeline.get_bus().timed_pop_filtered(
            5 * Gst.SECOND, Gst.MessageType.EOS | Gst.MessageType.ERROR
        )
        kind = (
            "EOS"
            if message and message.type == Gst.MessageType.EOS
            else "ERROR"
            if message and message.type == Gst.MessageType.ERROR
            else "missing"
        )
        reports.append(
            {
                "pipeline": description,
                "state_change": change.value_nick,
                "observed_state": state[1].value_nick,
                "message": kind,
                "error": str(message.parse_error()[0]) if kind == "ERROR" else None,
            }
        )
    finally:
        pipeline.set_state(Gst.State.NULL)
        final = pipeline.get_state(5 * Gst.SECOND)
        reports[-1]["final_state"] = final[1].value_nick
        if final[1] != Gst.State.NULL:
            raise RuntimeError("native pipeline cleanup did not reach NULL")
print(json.dumps({"gstreamer": Gst.version_string(), "reports": reports}))
if [r["message"] for r in reports] != ["EOS", "ERROR"]:
    raise RuntimeError("native EOS and ERROR outcomes were not both observed")
