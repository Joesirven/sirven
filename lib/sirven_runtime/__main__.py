"""sirven runtime: the Solo egress runtime on this machine.

  serve                 run the runtime in the foreground
  status                what the running runtime reports about itself
  fetch URL             ask the runtime to make one request, and print its result
  classify URL          ask the seam what it would decide, without sending anything
  decisions             the most recent entries of the decision log
  exec -- COMMAND ...   run COMMAND with HTTPS_PROXY and HTTP_PROXY pointing at the runtime
"""

import argparse
import base64
import importlib
import json
import os
import signal
import sys

from . import server
from .client import Client, RuntimeNotRunning


def load_policy(spec, settings_path):
    """--policy module:attribute names a factory called with the Solo settings."""
    module_name, _, attribute = spec.partition(":")
    factory = getattr(importlib.import_module(module_name), attribute or "policy")
    from .policy import load_settings
    return factory(load_settings(settings_path))


def serve(arguments):
    policy = load_policy(arguments.policy, arguments.settings) if arguments.policy else None
    instance = server.build(state_dir=arguments.state_dir, port=arguments.port, settings_path=arguments.settings,
                            fetcher_kind=arguments.fetcher, helper_path=arguments.helper, policy=policy)
    runtime = instance.runtime
    discovery = server.write_discovery(runtime)
    print("sirven runtime: listening on %s:%d, Solo, sending from your own connection" % (server.LISTEN_ADDRESS, runtime.port))
    print("  fingerprint: %s" % runtime.fetcher.fingerprint)
    print("  discovery file: %s" % discovery)
    print("  decision log: %s" % runtime.log.path)
    sys.stdout.flush()

    def stop(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop)
    try:
        instance.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        instance.server_close()
        try:
            os.remove(os.path.join(runtime.state_dir, "runtime.json"))
        except FileNotFoundError:
            pass
    return 0


def show(data):
    print(json.dumps(data, indent=2, sort_keys=True))


def fetch(arguments):
    body = arguments.data.encode("utf-8") if arguments.data is not None else None
    record = Client(arguments.state_dir).fetch(arguments.url, method=arguments.method, body=body,
                                               approval=arguments.approval)
    if not arguments.full and record.get("body_base64"):
        text = base64.b64decode(record["body_base64"]).decode("utf-8", "replace")
        record["body_preview"] = text[:500]
        del record["body_base64"]
    show(record)
    return 0 if record.get("outcome") == "ok" else 2


def run_command(arguments):
    command = arguments.command[1:] if arguments.command[:1] == ["--"] else arguments.command
    if not command:
        print("error: name a command after --", file=sys.stderr)
        return 64
    proxy = Client(arguments.state_dir).proxy_url()
    environment = dict(os.environ)
    for name in ("HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy"):
        environment[name] = proxy
    for name in ("NO_PROXY", "no_proxy", "ALL_PROXY", "all_proxy"):
        environment.pop(name, None)
    os.execvpe(command[0], command, environment)


def main(argv=None):
    parser = argparse.ArgumentParser(prog="sirven runtime", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--state-dir", help="where the token, discovery file, and decision log live (default: %s)"
                        % server.default_state_dir())
    commands = parser.add_subparsers(dest="action")

    serve_parser = commands.add_parser("serve", help="run the runtime in the foreground")
    serve_parser.add_argument("--port", type=int, default=server.DEFAULT_PORT, help="0 picks a free port")
    serve_parser.add_argument("--settings", help="the owner's Solo settings file (JSON)")
    serve_parser.add_argument("--fetcher", choices=("auto", "helper", "python"), default="auto")
    serve_parser.add_argument("--helper", help="path to the built sirven-fetch helper")
    serve_parser.add_argument("--policy", help="module:factory for a policy engine to plug into the seam")

    commands.add_parser("status", help="what the running runtime reports")
    fetch_parser = commands.add_parser("fetch", help="make one request through the runtime")
    fetch_parser.add_argument("url")
    fetch_parser.add_argument("--method", default="GET")
    fetch_parser.add_argument("--data", help="request body text")
    fetch_parser.add_argument("--approval", help="the reference to the user's approval of this action")
    fetch_parser.add_argument("--full", action="store_true", help="print the whole body, base64")
    classify_parser = commands.add_parser("classify", help="the seam's decision, nothing sent")
    classify_parser.add_argument("url")
    classify_parser.add_argument("--method", default="GET")
    commands.add_parser("decisions", help="recent decision log entries")
    exec_parser = commands.add_parser("exec", help="run a command with its proxy set to the runtime")
    exec_parser.add_argument("command", nargs=argparse.REMAINDER)

    arguments = parser.parse_args(argv)
    try:
        if arguments.action == "serve":
            return serve(arguments)
        if arguments.action == "status":
            show(Client(arguments.state_dir).status())
            return 0
        if arguments.action == "fetch":
            return fetch(arguments)
        if arguments.action == "classify":
            show(Client(arguments.state_dir).classify(arguments.url, arguments.method))
            return 0
        if arguments.action == "decisions":
            show(Client(arguments.state_dir).decisions())
            return 0
        if arguments.action == "exec":
            return run_command(arguments)
    except RuntimeNotRunning as error:
        print("error: %s" % error, file=sys.stderr)
        return 69
    parser.print_help()
    return 64


if __name__ == "__main__":
    sys.exit(main())
