"""a model context protocol server over standard input and output, serving the ride tools.

    python3 -m ride_connector.server            serve the fake demo backends
    python3 -m ride_connector.server --tools    print the tool list and exit

one JSON remote procedure call (JSON-RPC 2.0) message per line, as the model context protocol
standard input and output transport specifies. this is the reference wiring for a real
deployment: swap demo_connector for a RideConnector over real backends and nothing the agent
sees changes.
"""

import json
import sys

from .fake import FakeClock, demo_connector
from .schema import bundle_tools

PROTOCOL_VERSION = "2025-06-18"


class Server:
    def __init__(self, connector):
        self.connector = connector
        self.tools = bundle_tools(connector.validator.schema)

    def handle(self, message):
        """one request in, one response out (None for notifications)."""
        method = message.get("method")
        ident = message.get("id")
        if ident is None:
            return None
        if method == "initialize":
            result = {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "sirven-ride-connector", "version": self.connector.version},
            }
        elif method == "ping":
            result = {}
        elif method == "tools/list":
            result = {"tools": self.tools["tools"]}
        elif method == "tools/call":
            params = message.get("params") or {}
            is_error, payload = self.connector.call(params.get("name"), params.get("arguments") or {})
            result = {
                "content": [{"type": "text", "text": json.dumps(payload, sort_keys=True)}],
                "structuredContent": payload,
                "isError": is_error,
            }
        else:
            return {"jsonrpc": "2.0", "id": ident, "error": {"code": -32601, "message": "method not found"}}
        return {"jsonrpc": "2.0", "id": ident, "result": result}


def serve(connector, reader=sys.stdin, writer=sys.stdout):
    server = Server(connector)
    for line in reader:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            reply = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}}
        else:
            reply = server.handle(message)
        if reply is not None:
            writer.write(json.dumps(reply, sort_keys=True) + "\n")
            writer.flush()


def main(argv):
    if "--tools" in argv:
        print(json.dumps(bundle_tools(), indent=2, sort_keys=True))
        return 0
    connector, _, _ = demo_connector(FakeClock())
    serve(connector)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
