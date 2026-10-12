#!/usr/bin/env python3
"""the ride connector's demo server, with every fake backend refusing agents.

used by harness.py for the blocked scenario. like the demo server it runs on the real clock. it
changes one thing: each fake backend raises the backend error "blocked" on every quote. what the
agent sees is the contract's blocked error, the same one a real refusal produces.
"""

import sys

from ride_connector.fake import demo_connector
from ride_connector.gateway import system_clock
from ride_connector.server import serve


def main():
    connector, _, backends = demo_connector(system_clock)
    for backend in backends.values():
        backend.refuse = "blocked"
    serve(connector)
    return 0


if __name__ == "__main__":
    sys.exit(main())
