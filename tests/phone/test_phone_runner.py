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

# the fake mounter logs each call; "fail-after-first" fails only once the image was mounted before
MOUNTER = """
import sys
log, mode = sys.argv[1], sys.argv[2]
try:
    earlier = len(open(log).read().splitlines())
except OSError:
    earlier = 0
with open(log, "a") as handle:
    handle.write("mount %s %s\\n" % (sys.argv[3], sys.argv[4]))
if mode == "already":
    print("the developer disk image is already mounted", flush=True)
elif mode == "fail" or (mode == "fail-after-first" and earlier) or (mode == "fail-second" and earlier == 1):
    print("DeveloperDiskImage.dmg was not found for this iOS version", flush=True)
    sys.exit(1)
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
        self.mounts = os.path.join(self.folder, "mounts")
        self.saved_interrupt = signal.signal(signal.SIGINT, signal.default_int_handler)

    def tearDown(self):
        signal.signal(signal.SIGINT, self.saved_interrupt)
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

    def fake_mounter(self, mode="ok"):
        log = self.mounts

        def build(address, port):
            return [sys.executable, "-c", MOUNTER, log, mode, address, port]

        return build

    def supervisor(self, tunnel_lifetime=300, launcher_lifetime=300, **overrides):
        options = dict(backoff_start=0.01, backoff_cap=0.04, stable_seconds=60, poll_seconds=0.02,
                       tunnel_wait_seconds=10, stop_seconds=5)
        options.update(overrides)
        if "tunnel_command" not in options:
            options["tunnel_command"] = self.fake_tunnel(tunnel_lifetime)
        options.setdefault("build_launcher", self.fake_launcher(launcher_lifetime))
        options.setdefault("build_mounter", self.fake_mounter())
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

    def test_an_interrupt_right_after_a_child_starts_still_stops_that_child(self):
        started = []
        real_popen = subprocess.Popen

        def record(*args, **kwargs):
            process = real_popen(*args, **kwargs)
            started.append(process)
            self.addCleanup(lambda: (process.kill(), process.wait()))
            return process

        sleeping = [sys.executable, "-c", "import time; time.sleep(30)"]
        fake_threading = mock.Mock(Lock=threading.Lock)
        fake_threading.Thread.return_value.start.side_effect = KeyboardInterrupt
        with mock.patch.object(phone_bridge.subprocess, "Popen", side_effect=record), \
                mock.patch.object(phone_bridge, "threading", fake_threading):
            with self.assertRaises(KeyboardInterrupt):
                phone_bridge.Child(sleeping, time.monotonic)
        self.assertEqual(len(started), 1)
        self.assertIsNotNone(started[0].poll(), "the child must not keep running after the interrupt")

    def test_a_tunnel_restart_for_any_reason_resets_the_quick_failure_count(self):
        supervisor = self.supervisor()
        supervisor.quick_failures = 2
        with mock.patch.object(supervisor, "_start_tunnel"), mock.patch.object(supervisor, "_mount_image"), \
                mock.patch.object(supervisor, "_start_launcher", return_value=None), \
                mock.patch.object(supervisor, "_record"), contextlib.redirect_stdout(io.StringIO()):
            supervisor._restart_tunnel("the tunnel to the phone stopped")
        self.assertEqual(supervisor.quick_failures, 0)

    def test_the_device_identifier_is_never_printed_as_last_output(self):
        class Finished:
            def lines(self):
                return REAL_TUNNEL_LINES

        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            phone_bridge.show_last_output([Finished()])
        self.assertNotIn("00008110-000A1B2C3D4E5F60", output.getvalue())
        self.assertIn("  | RSD Address: fd35:4e2b:1c8f::1", output.getvalue())

    def test_the_developer_disk_image_is_mounted_with_the_tunnel_address_at_start(self):
        supervisor = self.supervisor(tunnel_lifetime=300, launcher_lifetime=300)
        self.run_until_interrupt(supervisor, 0.5)
        self.assertEqual(self.read_lines(self.mounts)[:1], ["mount 10.0.0.1 5001"])
        self.assertEqual(len(self.read_lines(self.launches)), 1)

    def test_an_image_that_is_already_mounted_counts_as_mounted(self):
        supervisor = self.supervisor(tunnel_lifetime=300, launcher_lifetime=300,
                                     build_mounter=self.fake_mounter("already"))
        printed = self.run_until_interrupt(supervisor, 0.5)
        self.assertIn("the phone runner is up", printed)
        self.assertEqual(len(self.read_lines(self.launches)), 1)

    def test_a_failed_mount_stops_the_runner_with_a_refusal_instead_of_looping(self):
        supervisor = self.supervisor(tunnel_lifetime=300, build_mounter=self.fake_mounter("fail"))
        guard = threading.Timer(5, lambda: os.kill(os.getpid(), signal.SIGINT))
        guard.start()
        self.addCleanup(guard.cancel)
        with self.assertRaises(phone_bridge.Refusal) as caught:
            supervisor.run()
        self.assertEqual(caught.exception.result, "image_not_mounted")
        self.assertIn("did not mount on the phone", caught.exception.said)
        self.assertIn("DeveloperDiskImage.dmg", caught.exception.said)
        self.assertEqual(len(self.read_lines(self.mounts)), 1, "the mount must not be retried in a loop")
        self.assertEqual(self.read_lines(self.launches), [], "the launcher must not start without a mounted image")

    def test_a_failed_mount_during_a_tunnel_restart_is_retried_and_the_runner_keeps_running(self):
        supervisor = self.supervisor(tunnel_lifetime=0.3, build_mounter=self.fake_mounter("fail-after-first"))
        printed = self.run_until_interrupt(supervisor, 1.5)
        self.assertGreaterEqual(len(self.read_lines(self.mounts)), 3, "the restart must keep trying the mount")
        self.assertIn("the phone may be locked: unlock it and keep it plugged in. trying again", printed)

    def test_a_mount_that_fails_during_a_restart_then_succeeds_brings_the_runner_back(self):
        supervisor = self.supervisor(tunnel_lifetime=0.3, build_mounter=self.fake_mounter("fail-second"))
        printed = self.run_until_interrupt(supervisor, 1.5)
        mounts = self.read_lines(self.mounts)
        self.assertGreaterEqual(len(mounts), 3)
        self.assertIn("the phone may be locked: unlock it and keep it plugged in. trying again", printed)
        self.assertIn("the tunnel and the launcher are running again", printed)
        self.assertGreaterEqual(len(self.read_lines(self.launches)), 2, "the launcher starts after the mount recovers")

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

    def test_setup_offers_two_signing_routes_and_checks_the_download_before_use(self):
        with contextlib.redirect_stdout(io.StringIO()) as printed:
            phone_bridge.command_setup("ABCDE12345", "com.example.wda")
        text = printed.getvalue()
        self.assertIn("ONE of these two routes", text)
        self.assertLess(text.index("route A"), text.index("curl -fL"))
        self.assertLess(text.index("curl -fL"), text.index("route B"), "the download belongs to route A only")
        self.assertIn("echo '%s  " % phone_bridge.WEBDRIVERAGENT_RUNNER_SHA256, text)
        self.assertIn("shasum -a 256 -c -", text)
        self.assertNotIn("Xcode > Settings", text)

    def test_setup_prints_the_xtool_route_without_team_or_bundle(self):
        with contextlib.redirect_stdout(io.StringIO()) as printed:
            phone_bridge.command_setup(None, None)
        text = printed.getvalue()
        self.assertLess(text.index("route A"), text.index("route B"))
        self.assertIn("XTL- and ends with com.facebook.WebDriverAgentRunner.xctrunner", text)
        self.assertIn("pymobiledevice3 apps list --rsd ADDRESS PORT", text)
        self.assertIn("SIRVEN_PHONE_RUNNER_BUNDLE=<runner identifier>", text)

    def test_start_is_listed_in_the_help(self):
        with contextlib.redirect_stdout(io.StringIO()) as printed:
            self.assertEqual(phone_bridge.main(["--help"]), 0)
        self.assertIn("  start ", printed.getvalue())


if __name__ == "__main__":
    unittest.main()
