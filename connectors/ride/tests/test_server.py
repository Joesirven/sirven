"""the model context protocol server: handshake, tool list, and tool calls over standard input and output."""

import io
import json
import os
import subprocess
import sys
import unittest

from helpers import HERE, VALIDATOR, quote_arguments
from ride_connector.fake import FakeClock, demo_connector
from ride_connector.server import PROTOCOL_VERSION, Server, serve
from ride_connector.schema import Validator


def request(ident, method, params=None):
    message = {"jsonrpc": "2.0", "id": ident, "method": method}
    if params is not None:
        message["params"] = params
    return message


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.connector, self.clock, self.backends = demo_connector(FakeClock())
        self.server = Server(self.connector)

    def tool(self, name, arguments):
        reply = self.server.handle(request(7, "tools/call", {"name": name, "arguments": arguments}))
        result = reply["result"]
        self.assertEqual(result["structuredContent"], json.loads(result["content"][0]["text"]))
        return result

    def test_handshake(self):
        reply = self.server.handle(request(1, "initialize", {"protocolVersion": PROTOCOL_VERSION, "capabilities": {}}))
        self.assertEqual(PROTOCOL_VERSION, reply["result"]["protocolVersion"])
        self.assertIn("tools", reply["result"]["capabilities"])
        self.assertIsNone(self.server.handle({"jsonrpc": "2.0", "method": "notifications/initialized"}))

    def test_tool_list_validates_real_traffic(self):
        tools = {tool["name"]: tool for tool in self.server.handle(request(2, "tools/list"))["result"]["tools"]}
        arguments = quote_arguments(self.clock)
        self.assertEqual([], Validator(tools["quote_ride"]["inputSchema"]).errors(arguments, tools["quote_ride"]["inputSchema"]))
        result = self.tool("quote_ride", arguments)
        output = tools["quote_ride"]["outputSchema"]
        self.assertEqual([], Validator(output).errors(result["structuredContent"], output))

    def test_round_trip_over_the_protocol(self):
        quote = self.tool("quote_ride", quote_arguments(self.clock))
        self.assertFalse(quote["isError"])
        option = [o for o in quote["structuredContent"]["options"] if o["provider"] == "Lyft"][0]
        booked = self.tool("book_ride", {"quote_id": option["quote_id"]})
        self.assertFalse(booked["isError"])
        booking_id = booked["structuredContent"]["booking"]["booking_id"]
        self.assertFalse(self.tool("get_ride", {"booking_id": booking_id})["isError"])
        cancelled = self.tool("cancel_ride", {"booking_id": booking_id})
        self.assertEqual("cancelled", cancelled["structuredContent"]["booking"]["status"])

    def test_errors_are_tool_errors_not_protocol_errors(self):
        result = self.tool("book_ride", {"quote_id": "qt_" + "a" * 26})
        self.assertTrue(result["isError"])
        self.assertEqual([], VALIDATOR.validate(result["structuredContent"], "error_output"))

    def test_unknown_method(self):
        self.assertEqual(-32601, self.server.handle(request(3, "resources/list"))["error"]["code"])

    def test_serve_reads_lines_and_survives_garbage(self):
        lines = "\n".join([json.dumps(request(1, "ping")), "not json", json.dumps(request(2, "tools/list"))]) + "\n"
        out = io.StringIO()
        serve(self.connector, io.StringIO(lines), out)
        replies = [json.loads(line) for line in out.getvalue().splitlines()]
        self.assertEqual([1, None, 2], [reply["id"] for reply in replies])
        self.assertEqual(-32700, replies[1]["error"]["code"])

    def test_runs_as_a_process(self):
        process = subprocess.run(
            [sys.executable, "-m", "ride_connector.server"],
            input=json.dumps(request(1, "tools/list")) + "\n",
            capture_output=True, text=True, cwd=os.path.dirname(HERE), timeout=30,
        )
        self.assertEqual(0, process.returncode, process.stderr)
        self.assertEqual(4, len(json.loads(process.stdout)["result"]["tools"]))


if __name__ == "__main__":
    unittest.main()
