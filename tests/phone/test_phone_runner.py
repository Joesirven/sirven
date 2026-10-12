"""the phone runner, lib/phone_bridge.py: the supervisor of the tunnel and the launcher, run with
small fake processes that print the lines the real tunnel prints. no phone, no network, and no
real pymobiledevice3. run with python3 -B, so no bytecode is left behind."""

import contextlib
import io
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
REPOSITORY = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPOSITORY, "lib"))

import phone_bridge  # noqa: E402

BUNDLE = "com.example.WebDriverAgentRunner.xctrunner"
REAL_TUNNEL_LINES = [
    "native tunnel is up",
    "Identifier: 00008110-000A1B2C3D4E5F60",
    "RSD Address: fd35:4e2b:1c8f::1",
    "RSD Port: 49152",
    "Use the follow connection option:",
    "--rsd fd35:4e2b:1c8f::1 49152",
]

# the fake tunnel counts its starts in a file and prints the next address each time
TUNNEL = """
import sys, time
count_file, lifetime = sys.argv[1], float(sys.argv[2])
try:
    starts = int(open(count_file).read())
except OSError:
    starts = 0
starts += 1
open(count_file, "w").write(str(starts))
print("Identifier: fake-identifier", flush=True)
print("RSD Address: 10.0.0.%d" % starts, flush=True)
print("RSD Port: %d" % (5000 + starts), flush=True)
print("Use the follow connection option:", flush=True)
print("--rsd 10.0.0.%d %d" % (starts, 5000 + starts), flush=True)
time.sleep(lifetime)
"""

# the fake tunnel prints an address on its first start only; later starts exit silently
TUNNEL_ONCE = """
import sys, time
count_file = sys.argv[1]
try:
    starts = int(open(count_file).read())
except OSError:
    starts = 0
starts += 1
open(count_file, "w").write(str(starts))
if starts > 1:
    sys.exit(0)
print("RSD Address: 10.0.0.1", flush=True)
print("RSD Port: 5001", flush=True)
time.sleep(0.3)
"""

# the fake launcher writes its arguments to a log, then lives for its lifetime
LAUNCHER = """
import sys, time
log, lifetime = sys.argv[1], float(sys.argv[2])
with open(log, "a") as handle:
    handle.write(" ".join(sys.argv[3:]) + "\\n")
time.sleep(lifetime)
"""


class RunnerTest(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="sirven-runner-test.")
        self.saved_environment = dict(os.environ)
        os.environ["SIRVEN_PHONE_DIR"] = os.path.join(self.folder, "state")
        os.environ.pop("SIRVEN_USBMUX_SOCKET", None)
        self.tunnel_starts = os.path.join(self.folder, "tunnel-starts")
        self.launches = os.path.join(self.folder, "launches")

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.saved_environment)
        shutil.rmtree(self.folder, ignore_errors=True)

    def sleeping_process(self):
        sleeper = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])

        def reap():
            sleeper.kill()
            sleeper.wait()

        self.addCleanup(reap)
        return sleeper

    def fake_tunnel(self, lifetime):
        return [sys.executable, "-c", TUNNEL, self.tunnel_starts, str(lifetime)]

    def fake_launcher(self, lifetime):
        log = self.launches

        def build(bundle, address, port):
            return [sys.executable, "-c", LAUNCHER, log, str(lifetime), bundle, address, port]

        return build

    def supervisor(self, tunnel_lifetime=300, launcher_lifetime=300, **overrides):
        options = dict(backoff_start=0.01, backoff_cap=0.04, stable_seconds=60, poll_seconds=0.02,
                       tunnel_wait_seconds=10, stop_seconds=5)
        options.update(overrides)
        if "tunnel_command" not in options:
            options["tunnel_command"] = self.fake_tunnel(tunnel_lifetime)
        options.setdefault("build_launcher", self.fake_launcher(launcher_lifetime))
        return phone_bridge.RunnerSupervisor(BUNDLE, **options)

    def run_until_interrupt(self, supervisor, seconds, before=None, signal_number=signal.SIGINT):
        """run until a Ctrl-C or the given signal, sent by a timer after the seconds, and return what was printed."""

        def interrupt_later():
            if before is not None:
                before()
            os.kill(os.getpid(), signal_number)

        timer = threading.Timer(seconds, interrupt_later)
        timer.start()
        try:
            with contextlib.redirect_stdout(io.StringIO()) as printed:
                supervisor.run()
        finally:
            timer.cancel()
        return printed.getvalue()

    def read_text(self, path):
        with open(path) as handle:
            return handle.read().strip()

    def read_lines(self, path):
        if not os.path.exists(path):
            return []
        return self.read_text(path).splitlines()

    def runner_file(self):
        return phone_bridge.state_file("runner.json")

    def record(self):
        with open(self.runner_file()) as handle:
            return json.load(handle)

    def test_a_missing_or_malformed_bundle_variable_refuses_with_64(self):
        for value in (None, "", "bad bundle!", "com.example/evil"):
            if value is None:
                os.environ.pop(phone_bridge.RUNNER_BUNDLE_VARIABLE, None)
            else:
                os.environ[phone_bridge.RUNNER_BUNDLE_VARIABLE] = value
            errors = io.StringIO()
            with contextlib.redirect_stderr(errors), self.assertRaises(SystemExit) as caught:
                phone_bridge.main(["start"])
            self.assertEqual(caught.exception.code, 64)
            self.assertIn("SIRVEN_PHONE_RUNNER_BUNDLE", errors.getvalue())
            self.assertIn("sirven phone setup", errors.getvalue())
        self.assertFalse(os.path.exists(self.runner_file()))

    def test_a_missing_pymobiledevice3_refuses_with_the_install_line(self):
        os.environ[phone_bridge.RUNNER_BUNDLE_VARIABLE] = BUNDLE
        empty = os.path.join(self.folder, "empty")
        os.mkdir(empty)
        errors = io.StringIO()
        with mock.patch.dict(os.environ, {"PATH": empty}), contextlib.redirect_stderr(errors), \
                self.assertRaises(SystemExit) as caught:
            phone_bridge.main(["start"])
        self.assertEqual(caught.exception.code, 1)
        self.assertIn("pymobiledevice3 was not found on PATH", errors.getvalue())
        self.assertIn("uv tool install pymobiledevice3==11.28.2", errors.getvalue())

    def test_the_tunnel_endpoint_is_read_from_the_lines_the_tunnel_prints(self):
        self.assertEqual(phone_bridge.tunnel_endpoint(REAL_TUNNEL_LINES), ("fd35:4e2b:1c8f::1", "49152"))
        self.assertIsNone(phone_bridge.tunnel_endpoint(["native tunnel is up", "Identifier: x"]))
        self.assertIsNone(phone_bridge.tunnel_endpoint(["RSD Address: fd35:4e2b:1c8f::1"]))
        self.assertIsNone(phone_bridge.tunnel_endpoint(["RSD Port: 49152"]))
        self.assertIsNone(phone_bridge.tunnel_endpoint([]))

    def test_a_tunnel_that_prints_no_address_in_time_is_refused(self):
        supervisor = self.supervisor(tunnel_command=[sys.executable, "-c", "import time; time.sleep(30)"],
                                     tunnel_wait_seconds=0.3)
        with self.assertRaises(phone_bridge.Refusal) as caught:
            supervisor.start()
        self.assertEqual(caught.exception.result, "tunnel_no_address")
        self.assertIn("did not print its remote service discovery address", caught.exception.said)

    def test_an_interrupt_while_the_tunnel_is_still_printing_leaves_no_tunnel_running(self):
        supervisor = self.supervisor(tunnel_command=[sys.executable, "-c", "import time; time.sleep(30)"],
                                     tunnel_wait_seconds=30)
        made = []
        real_child = phone_bridge.Child

        def spy(*args, **kwargs):
            child = real_child(*args, **kwargs)
            made.append(child)
            return child

        with mock.patch.object(phone_bridge, "Child", side_effect=spy):
            self.run_until_interrupt(supervisor, 0.3)
        self.assertEqual(len(made), 1)
        self.assertIsNotNone(made[0].process.poll(), "the tunnel process must not outlive the interrupt")

    def test_a_tunnel_that_exits_without_an_address_is_refused_at_once(self):
        supervisor = self.supervisor(tunnel_command=[sys.executable, "-c", "print('goodbye')"],
                                     tunnel_wait_seconds=30)
        started = time.monotonic()
        with self.assertRaises(phone_bridge.Refusal) as caught:
            supervisor.start()
        self.assertIn("stopped before it printed", caught.exception.said)
        self.assertLess(time.monotonic() - started, 10)

    def test_a_missing_pymobiledevice3_is_refused_in_plain_words(self):
        supervisor = self.supervisor(tunnel_command=["/no/such/sirven-test-tool"])
        with self.assertRaises(phone_bridge.Refusal) as caught:
            supervisor.start()
        self.assertEqual(caught.exception.said, phone_bridge.MISSING_TOOL)

    def test_a_dead_launcher_is_restarted_alone(self):
        supervisor = self.supervisor(tunnel_lifetime=300, launcher_lifetime=0.3, stable_seconds=0.2)
        printed = self.run_until_interrupt(supervisor, 1.5)
        self.assertEqual(self.read_text(self.tunnel_starts), "1", "the tunnel must not restart")
        launched = self.read_lines(self.launches)
        self.assertGreaterEqual(len(launched), 2)
        self.assertTrue(all(line == "%s 10.0.0.1 5001" % BUNDLE for line in launched), launched)
        self.assertIn("the launcher stopped; starting it again", printed)
        self.assertNotIn("the tunnel to the phone stopped", printed)

    def test_a_launcher_that_stops_shows_the_reason_it_printed(self):
        complaint = [sys.executable, "-c", "import sys; print('the runner is not installed on the phone'); sys.exit(1)"]
        supervisor = self.supervisor(tunnel_lifetime=300, build_launcher=lambda bundle, address, port: complaint)
        printed = self.run_until_interrupt(supervisor, 0.5)
        self.assertIn("  | the runner is not installed on the phone", printed)

    def test_a_dead_tunnel_restarts_the_tunnel_and_the_launcher_with_the_new_address(self):
        supervisor = self.supervisor(tunnel_lifetime=0.3, launcher_lifetime=300)
        printed = self.run_until_interrupt(supervisor, 1.5)
        starts = int(self.read_text(self.tunnel_starts))
        self.assertGreaterEqual(starts, 2)
        addresses = [line.split()[1] for line in self.read_lines(self.launches)]
        self.assertIn("10.0.0.1", addresses)
        self.assertIn("10.0.0.2", addresses, "the launcher must start again with the new address")
        self.assertTrue(set(addresses) <= {"10.0.0.%d" % number for number in range(1, starts + 1)}, addresses)
        self.assertIn("the tunnel to the phone stopped; the launcher stops with it", printed)

    def test_three_quick_launcher_failures_restart_the_tunnel_for_a_new_address(self):
        supervisor = self.supervisor(tunnel_lifetime=300, launcher_lifetime=0)
        printed = self.run_until_interrupt(supervisor, 1.5)
        self.assertGreaterEqual(int(self.read_text(self.tunnel_starts)), 2)
        addresses = [line.split()[1] for line in self.read_lines(self.launches)]
        self.assertEqual(addresses[:3], ["10.0.0.1"] * 3, "three launches before the tunnel restarts")
        self.assertEqual(addresses[3], "10.0.0.2", "the launcher must start with the new address")
        self.assertIn("the launcher failed 3 times in a row", printed)

    def test_a_tunnel_that_does_not_come_back_is_retried_and_no_launcher_starts_without_an_address(self):
        supervisor = self.supervisor(tunnel_command=[sys.executable, "-c", TUNNEL_ONCE, self.tunnel_starts],
                                     launcher_lifetime=300)
        printed = self.run_until_interrupt(supervisor, 1.5)
        self.assertGreaterEqual(int(self.read_text(self.tunnel_starts)), 3)
        self.assertIn("the tunnel did not come back", printed)
        launched = [line.split()[1] for line in self.read_lines(self.launches)]
        self.assertEqual(launched, ["10.0.0.1"], "only the launcher from the first, good tunnel start")

    def test_a_clean_stop_terminates_both_children_and_removes_the_runner_file(self):
        supervisor = self.supervisor(tunnel_lifetime=300, launcher_lifetime=300)
        seen = {}

        def capture():
            seen.update(self.record())

        printed = self.run_until_interrupt(supervisor, 1.0, before=capture)
        self.assertFalse(phone_bridge.process_alive(seen["tunnel"]))
        self.assertFalse(phone_bridge.process_alive(seen["launcher"]))
        self.assertFalse(os.path.exists(self.runner_file()))
        self.assertIn("the phone runner stopped", printed)

    def test_a_hang_up_stops_both_children_like_a_ctrl_c(self):
        supervisor = self.supervisor(tunnel_lifetime=300, launcher_lifetime=300)
        seen = {}

        def capture():
            seen.update(self.record())

        printed = self.run_until_interrupt(supervisor, 1.0, before=capture, signal_number=signal.SIGHUP)
        self.assertFalse(phone_bridge.process_alive(seen["tunnel"]))
        self.assertFalse(phone_bridge.process_alive(seen["launcher"]))
        self.assertFalse(os.path.exists(self.runner_file()))
        self.assertIn("the phone runner stopped", printed)

    def test_a_failed_launcher_stop_still_stops_the_tunnel_and_keeps_the_runner_file(self):
        supervisor = self.supervisor()
        launcher = mock.Mock()
        launcher.stop.side_effect = RuntimeError("the launcher would not stop")
        tunnel = mock.Mock()
        supervisor.launcher, supervisor.tunnel = launcher, tunnel
        phone_bridge.write_private(self.runner_file(), "{}")
        with self.assertRaises(RuntimeError):
            supervisor.stop()
        tunnel.stop.assert_called_once()
        self.assertIsNone(supervisor.tunnel)
        self.assertTrue(os.path.exists(self.runner_file()), "a child may still run, so the record stays")

    def test_the_runner_file_records_the_supervisor_and_both_children(self):
        supervisor = self.supervisor(tunnel_lifetime=300, launcher_lifetime=300)
        seen = {}

        def capture():
            seen.update(self.record())

        self.run_until_interrupt(supervisor, 1.0, before=capture)
        self.assertEqual(seen["supervisor"], os.getpid())
        self.assertNotEqual(seen["tunnel"], seen["launcher"])
        self.assertTrue(seen["started"].endswith("Z"))

    def test_the_wait_before_a_restart_doubles_and_is_capped(self):
        backoff = phone_bridge.Backoff(1, 30, 60)
        self.assertEqual([backoff.next_wait(0) for _ in range(7)], [1, 2, 4, 8, 16, 30, 30])
        self.assertEqual(backoff.next_wait(61), 1, "a process that stayed up for a minute starts again at one second")
        self.assertEqual(backoff.next_wait(5), 2)
        self.assertEqual((phone_bridge.BACKOFF_START_SECONDS, phone_bridge.BACKOFF_CAP_SECONDS,
                          phone_bridge.STABLE_SECONDS), (1, 30, 60))

    def test_status_says_running_or_not_running_from_the_runner_file(self):
        dead = subprocess.Popen([sys.executable, "-c", "pass"])
        dead.wait()
        self.assertEqual(phone_bridge.runner_status(), {"tunnel": "not running", "launcher": "not running"})
        with open(self.runner_file(), "w") as handle:
            json.dump({"supervisor": os.getpid(), "tunnel": os.getpid(), "launcher": dead.pid,
                       "started": "2026-10-12T09:00:00Z"}, handle)
        held = phone_bridge.take_runner_lock()
        self.addCleanup(held.close)
        self.assertEqual(phone_bridge.runner_status(), {"tunnel": "running", "launcher": "not running"})

    def test_children_left_behind_by_a_killed_supervisor_read_as_not_running(self):
        sleeper = self.sleeping_process()
        with open(self.runner_file(), "w") as handle:
            json.dump({"supervisor": 999999, "tunnel": sleeper.pid, "launcher": sleeper.pid,
                       "started": "2026-10-12T09:00:00Z"}, handle)
        self.assertEqual(phone_bridge.runner_status(), {"tunnel": "not running", "launcher": "not running"})

    def test_a_second_supervisor_is_refused_while_one_holds_the_lock(self):
        held = phone_bridge.take_runner_lock()
        self.addCleanup(held.close)
        with self.assertRaises(phone_bridge.Refusal) as caught:
            self.supervisor().run()
        self.assertEqual(caught.exception.result, "already_running")
        self.assertFalse(os.path.exists(self.runner_file()))

    def test_processes_left_by_an_earlier_run_block_a_new_start(self):
        sleeper = self.sleeping_process()
        with open(self.runner_file(), "w") as handle:
            json.dump({"supervisor": 999999, "tunnel": sleeper.pid, "launcher": sleeper.pid,
                       "started": "2026-10-12T09:00:00Z"}, handle)
        with self.assertRaises(phone_bridge.Refusal) as caught:
            self.supervisor().run()
        self.assertEqual(caught.exception.result, "leftover_processes")
        self.assertIn(str(sleeper.pid), caught.exception.said)
        self.assertTrue(os.path.exists(self.runner_file()))

    def test_phone_status_carries_the_tunnel_and_launcher_words(self):
        unplugged = {"result": "no_phone", "said": "no iPhone is plugged in over USB"}
        with mock.patch.object(phone_bridge, "detect", return_value=unplugged):
            report = phone_bridge.Phone().status()
        self.assertEqual(report["tunnel"], "not running")
        self.assertEqual(report["launcher"], "not running")

    def test_start_is_listed_in_the_help(self):
        with contextlib.redirect_stdout(io.StringIO()) as printed:
            self.assertEqual(phone_bridge.main(["--help"]), 0)
        self.assertIn("  start ", printed.getvalue())


if __name__ == "__main__":
    unittest.main()
