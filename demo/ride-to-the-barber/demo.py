#!/usr/bin/env python3
"""the ride-to-the-barber rehearsal. see README.md next to this file for the demo script.

  demo.py run [--yes] [--scripted-concierge] [--record DIR] [--state DIR]
      the agent side: calendar, consent, quote, book, calendar write-back.
  demo.py console --state DIR [--name NAME]
      the concierge console, for a person, in a second terminal.
  demo.py gates
      print the ship gates and exit 0 only when the human-concierge gate is open.
"""

import argparse
import os
import sys
import tempfile
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ride_demo import agent, console, gates  # noqa: E402
from ride_demo.concierge_queue import ConciergeQueue  # noqa: E402
from ride_demo.recorder import Recorder  # noqa: E402

SCENARIOS = ("normal", "late_quote", "fare_over_cap")


def default_state():
    return os.path.join(tempfile.gettempdir(), "sirven-ride-rehearsal")


def main(argv=None):
    parser = argparse.ArgumentParser(prog="demo.py", description=__doc__.split("\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)

    run = commands.add_parser("run", help="the agent side of the rehearsal")
    run.add_argument("--request", default=agent.DEMO_SENTENCE)
    run.add_argument("--state", help="where the queue, calendar copy, and records go (fresh by default)")
    run.add_argument("--record", help="also write transcript.txt, run.cast, and events.jsonl here")
    run.add_argument("--yes", action="store_true", help="answer yes to every question, and say so on screen")
    run.add_argument("--no-concierge", action="store_true", help="answer no when asked if a person may see the trip")
    run.add_argument("--scripted-concierge", action="store_true",
                     help="run a timed, clearly labeled operator at the concierge console instead of a person")
    run.add_argument("--scenario", choices=SCENARIOS, default="normal", help="what the scripted operator does")
    run.add_argument("--concierge-name", default="Jose (rehearsal)")
    run.add_argument("--operator-delays", default="2,6,2,14",
                     help="scripted operator seconds: before claiming the quote, quoting, claiming the booking, booking")
    run.add_argument("--quote-wait", type=float, default=30, help="seconds to wait for a quote; the target is 30")
    run.add_argument("--booking-wait", type=float, default=90, help="seconds to wait for a booking; the target is 90")
    run.add_argument("--live", action="store_true", help="ask for a live fire; always refused in this build")

    operate = commands.add_parser("console", help="the concierge console a person operates")
    operate.add_argument("--state", default=default_state())
    operate.add_argument("--name", default="Jose (rehearsal)")
    operate.add_argument("--once", action="store_true", help="leave after one booking or one decline")

    commands.add_parser("gates", help="print the ship gates")

    args = parser.parse_args(argv)

    if args.command == "gates":
        gate = gates.concierge_gate(agent.REPO_DIR, agent.COPY_PATH)
        for line in gates.describe(gate) + gates.describe(gates.peer_routing_gate()):
            print(line)
        return 0 if gate["open"] else 1

    if args.command == "console":
        try:
            console.interactive(ConciergeQueue(os.path.join(args.state, "concierge-queue")), args.name, once=args.once)
        except (KeyboardInterrupt, EOFError):
            print()
        return 0

    if args.state is None:
        if args.scripted_concierge:
            args.state = tempfile.mkdtemp(prefix="sirven-ride-rehearsal.")
        else:
            args.state = default_state()
            print("state directory: %s (start the console with: demo.py console --state %s)" % (args.state, args.state))
    args.interactive = sys.stdin.isatty()
    recorder = Recorder(args.record, title="sirven rehearsal %s" % datetime.now().strftime("%Y-%m-%d %H:%M"))
    operator = None
    if args.scripted_concierge:
        queue = ConciergeQueue(os.path.join(args.state, "concierge-queue"))
        operator = console.ScriptedOperator(
            queue, args.concierge_name, lambda line: recorder.say(line, who="concierge"), scenario=args.scenario,
            delays=tuple(float(part) for part in args.operator_delays.split(","))).start()
    try:
        status = agent.run(args, recorder)
    finally:
        if operator:
            operator.stop()
    recorder.event("finished", exit_status=status)
    recorder.close()
    return status


if __name__ == "__main__":
    sys.exit(main())
