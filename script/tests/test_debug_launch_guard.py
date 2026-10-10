#!/usr/bin/env python3
"""Offline whole-entry-point regression; every mutating command is a Bash stub.

Outputs remain below this worktree's .build. The same tests can be run against
the unmodified script with --script to demonstrate the unsafe legacy boundary.
"""

import argparse
import ctypes
import errno
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
BUNDLE_ID = "io.github.obisoldbee.UsageButler"
MODES = [(), ("run",), ("--debug",), ("debug",), ("--logs",), ("logs",),
         ("--telemetry",), ("telemetry",), ("--verify",), ("verify",),
         ("--panel",), ("--fixture-panel",), ("--network-panel",)]
SCRIPT = ROOT / "script/build_and_run.sh"
OUTPUT = None

SHIMS = r'''
record_effect() { printf '%s\n' "$1" >> "$UB_TEST_EFFECTS"; }
xcodegen() { record_effect xcodegen; }
xcodebuild() { record_effect xcodebuild; }
pkill() { record_effect pkill; return 1; }
pgrep() { if [[ -s "$UB_TEST_PID" ]]; then cat "$UB_TEST_PID"; fi; }
ps() {
  if [[ "$1" == -p && -s "$UB_TEST_PID" ]]; then
    if [[ "$4" == comm= ]]; then printf '%s\n' "$UB_TEST_BINARY";
    elif [[ "$4" == lstart= ]]; then printf 'Sat Oct  3 00:00:00 2026\n';
    else return 97; fi
  elif [[ "$1" == -axo ]]; then return 0;
  else return 1; fi
}
kill() { record_effect kill; : > "$UB_TEST_PID"; }
sleep() { :; }
lldb() { record_effect lldb; }
function /usr/bin/codesign { record_effect codesign; }
function /usr/bin/open { record_effect open; printf '4243\n' > "$UB_TEST_PID"; }
function /usr/bin/log { record_effect log; }
function /usr/libexec/PlistBuddy {
  case "$2" in
    'Print :CFBundleIdentifier') printf 'io.github.obisoldbee.UsageButler\n' ;;
    'Print :CFBundleShortVersionString') printf '0.5.8\n' ;;
    'Print :CFBundleVersion') printf '20\n' ;;
    *) return 98 ;;
  esac
}
python3() {
  "$UB_TEST_PYTHON" -B "$UB_TEST_RUNNER" --fixture-probe "$@"
}
'''


def load_guard(path):
    spec = importlib.util.spec_from_file_location("debug_launch_guard", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def fixture_probe(arguments):
    # Run the real guard policy. Only its OS observations are substituted;
    # production code has no environment switch or force/test bypass.
    if arguments[0] == "-B":
        arguments = arguments[1:]
    module = load_guard(Path(arguments[0]))
    candidate = Path(arguments[arguments.index("--app-binary") + 1])
    scenario = os.environ["UB_TEST_SCENARIO"]
    probe_calls = Path(os.environ["UB_TEST_PROBES"])
    round_number = len(probe_calls.read_text().splitlines()) + 1
    with probe_calls.open("a") as stream:
        stream.write("preflight\n")

    class FixtureProbe:
        uid = 501
        home = Path("/fixture user with spaces")

        def exists(self, path):
            if scenario == "installation_probe_failure":
                raise OSError("fixture permission denied")
            if path == Path("/Applications/Usage-Butler.app"):
                return scenario in {"installed_enabled", "installed_gui_exited", "installed_wrong_identity"} or (scenario == "installation_appears_during_build" and round_number >= 2)
            if path == self.home / "Applications/Usage-Butler.app":
                return scenario == "user_installation"
            suffixes = {"history_residue": f"Application Support/{BUNDLE_ID}/NetworkHistory",
                        "quota_cache": "Application Support/Usage-Butler/quota-cache",
                        "memory_history": "Application Support/Usage-Butler/memory-history",
                        "persisted_preferences": f"Preferences/{BUNDLE_ID}.plist"}
            return scenario in suffixes and path == self.home / "Library" / suffixes[scenario]

        def bundle_identifier(self, path):
            return "unrelated.app" if scenario == "installed_wrong_identity" else BUNDLE_ID

        def cached_preferences_present(self):
            if scenario == "preferences_probe_failure":
                raise OSError("fixture preferences API unavailable")
            return scenario in {"preferences_enabled", "preferences_binding"}

        def service_registered(self):
            if scenario == "service_probe_failure":
                raise OSError("fixture launchctl denied")
            return scenario == "registered_service" or (scenario == "service_appears_before_launch" and round_number >= 3)

        def processes(self):
            if scenario == "process_probe_failure":
                raise OSError("fixture process snapshot unavailable")
            if scenario == "pid_path_probe_failure":
                raise OSError("fixture proc_pidpath denied")
            processes = [module.RunningProcess(4242, candidate, BUNDLE_ID)]
            if scenario == "helper_only":
                processes.append(module.RunningProcess(6001, Path("/other path/Usage-Butler.app/Contents/MacOS/UsageButlerNetworkAgent"), BUNDLE_ID))
            if scenario == "foreign_gui":
                processes.append(module.RunningProcess(6002, Path("/different path/Usage-Butler.app/Contents/MacOS/Usage-Butler"), BUNDLE_ID))
            if scenario == "renamed_gui_same_identity":
                processes.append(module.RunningProcess(6003, Path("/different path/Renamed.app/Contents/MacOS/Renamed"), BUNDLE_ID))
            if scenario == "local_helper":
                processes.append(module.RunningProcess(6004, candidate.with_name("UsageButlerNetworkAgent"), BUNDLE_ID))
            if scenario == "unrelated_app":
                processes.append(module.RunningProcess(6005, Path("/different path/Usage-Butler.app/Contents/MacOS/Usage-Butler"), "unrelated.app"))
            return processes

    return module.main(arguments[1:], probe=FixtureProbe())


class EntryPointTests(unittest.TestCase):
    def invoke(self, scenario, mode):
        case_root = Path(tempfile.mkdtemp(prefix=scenario + " ", dir=OUTPUT))
        project = case_root / "source with spaces"
        script_dir = project / "script"
        script_dir.mkdir(parents=True)
        copied_script = script_dir / "build_and_run.sh"
        shutil.copyfile(SCRIPT, copied_script)
        guard = ROOT / "script/debug_launch_guard.py"
        if guard.exists() and scenario != "missing_probe":
            shutil.copyfile(guard, script_dir / guard.name)
        (project / "project.yml").write_text("name: OfflineScriptFixture\n")
        app = project / ".build/DerivedData/Build/Products/Debug/Usage-Butler.app"
        binaries = app / "Contents/MacOS"
        binaries.mkdir(parents=True)
        for name in ("Usage-Butler", "UsageButlerNetworkAgent"):
            binary = binaries / name
            binary.write_text("offline placeholder; never executed\n")
            binary.chmod(0o700)
        with (app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": BUNDLE_ID}, stream)
        shims = case_root / "shims.bash"
        shims.write_text(SHIMS + (r'''
command() {
  if [[ "$1" == -v && "$2" == python3 ]]; then return 1; fi
  builtin command "$@"
}
''' if scenario == "missing_python" else ""))
        effects = case_root / "effects.txt"
        effects.touch()
        pid_file = case_root / "fake-pid.txt"
        pid_file.write_text("4242\n")
        probes = case_root / "probes.txt"
        probes.touch()
        env = dict(os.environ, BASH_ENV=str(shims), UB_TEST_EFFECTS=str(effects),
                   UB_TEST_PID=str(pid_file), UB_TEST_BINARY=str(binaries / "Usage-Butler"),
                   UB_TEST_PYTHON=sys.executable, UB_TEST_RUNNER=str(Path(__file__).resolve()),
                   UB_TEST_SCENARIO=scenario, UB_TEST_PROBES=str(probes),
                   USAGE_BUTLER_CODESIGN_IDENTITY="offline fixture signing identity",
                   USAGE_BUTLER_OFFLINE_FIXTURE="1")
        result = subprocess.run(["/bin/bash", str(copied_script), *mode], cwd=project,
                                env=env, text=True, capture_output=True, timeout=10)
        observed = effects.read_text().splitlines()
        receipt = {"scenario": scenario, "mode": list(mode), "script": str(SCRIPT),
                   "returncode": result.returncode, "effects": observed,
                   "preflights": len(probes.read_text().splitlines()),
                   "stdout": result.stdout, "stderr": result.stderr}
        with (case_root / "result.json").open("x") as stream:
            json.dump(receipt, stream, indent=2)
        return receipt

    def test_conflicts_and_unknowns_stop_before_every_side_effect_in_all_modes(self):
        scenarios = ["installed_enabled", "installed_gui_exited", "user_installation",
                     "installed_wrong_identity", "helper_only", "foreign_gui",
                     "renamed_gui_same_identity", "local_helper", "registered_service",
                     "history_residue", "quota_cache", "memory_history", "persisted_preferences",
                     "preferences_enabled", "preferences_binding", "installation_probe_failure",
                     "preferences_probe_failure", "service_probe_failure", "process_probe_failure",
                     "pid_path_probe_failure", "missing_probe", "missing_python"]
        for scenario in scenarios:
            for mode in MODES:
                with self.subTest(scenario=scenario, mode=mode):
                    receipt = self.invoke(scenario, mode)
                    # Assert effects first: an error printed after build/kill/sign/open
                    # is still unsafe, regardless of its exit status or wording.
                    self.assertEqual(receipt["effects"], [], receipt)
                    self.assertEqual(receipt["returncode"], 3, receipt)
                    self.assertIn("Debug launch refused", receipt["stderr"])
                    self.assertIn("Next:", receipt["stderr"])

    def test_clean_environment_and_exact_owned_gui_remain_usable_in_all_modes(self):
        for scenario in ("clean", "unrelated_app"):
            for mode in MODES:
                with self.subTest(scenario=scenario, mode=mode):
                    receipt = self.invoke(scenario, mode)
                    self.assertEqual(receipt["returncode"], 0, receipt)
                    self.assertEqual(receipt["effects"][:3], ["kill", "xcodegen", "xcodebuild"], receipt)
                    self.assertEqual(receipt["effects"].count("codesign"), 3, receipt)
                    launch = "lldb" if mode in [("--debug",), ("debug",)] else "open"
                    self.assertIn(launch, receipt["effects"], receipt)
                    self.assertNotIn("pkill", receipt["effects"], receipt)
                    if SCRIPT == ROOT / "script/build_and_run.sh":
                        self.assertEqual(receipt["preflights"], 3, receipt)

    def test_new_conflict_during_build_or_before_launch_is_rechecked(self):
        for scenario in ("installation_appears_during_build", "service_appears_before_launch"):
            for mode in MODES:
                with self.subTest(scenario=scenario, mode=mode):
                    receipt = self.invoke(scenario, mode)
                    self.assertEqual(receipt["returncode"], 3, receipt)
                    expected = ["kill", "xcodegen", "xcodebuild"]
                    if scenario == "service_appears_before_launch":
                        expected += ["codesign"] * 3
                    self.assertEqual(receipt["effects"], expected, receipt)

    def test_bad_arguments_stop_before_probes_and_side_effects(self):
        for mode in [("--force",), ("--unknown",), ("",), ("run", "--panel")]:
            with self.subTest(mode=mode):
                receipt = self.invoke("installed_enabled", mode)
                self.assertEqual(receipt["returncode"], 2, receipt)
                self.assertEqual(receipt["effects"], [], receipt)
                self.assertEqual(receipt["preflights"], 0, receipt)


class FunctionStub:
    def __init__(self, function):
        self.function = function

    def __call__(self, *arguments):
        return self.function(*arguments)


class NativeProbeTests(unittest.TestCase):
    """Exercise native adapter parsing/API failures without real host probes."""

    @classmethod
    def setUpClass(cls):
        cls.guard = load_guard(ROOT / "script/debug_launch_guard.py")

    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix="native adapter ", dir=OUTPUT))
        self.probe = object.__new__(self.guard.NativeProbe)
        self.probe.uid = 501
        self.probe.home = self.directory

    def test_launchctl_exact_label_and_two_successful_domains(self):
        snapshots = ["gui/501 = {\n services = { unrelated.label = {} }\n}\n",
                     "user/501 = {\n services = { unrelated.label = {} }\n}\n"]
        with mock.patch.object(self.probe, "command", side_effect=snapshots) as command:
            self.assertFalse(self.probe.service_registered())
            self.assertEqual(command.call_args_list,
                             [mock.call(["/bin/launchctl", "print", "gui/501"]),
                              mock.call(["/bin/launchctl", "print", "user/501"])])
        for label, expected in [(self.guard.SERVICE_LABEL, True),
                                (self.guard.SERVICE_LABEL + ".validation", False),
                                (BUNDLE_ID + ".Validation.History.test.network-agent", False)]:
            with self.subTest(label=label), mock.patch.object(self.probe, "command",
                    side_effect=[f"gui/501 = {{\n services = {{ {label} = {{}} }}\n}}\n", snapshots[1]]):
                self.assertEqual(self.probe.service_registered(), expected)

    def test_launchctl_failure_or_truncated_success_is_unknown(self):
        for output in ("", "gui/501 = {", "other/501 = { services = {} }", "gui/501 = { unrelated = {} }"):
            with self.subTest(output=output), mock.patch.object(self.probe, "command", return_value=output):
                with self.assertRaises(self.guard.ProbeUnavailable):
                    self.probe.service_registered()
        for result in [subprocess.CompletedProcess([], 113, "", "Could not find domain"),
                       subprocess.CompletedProcess([], 0, "snapshot", "permission denied")]:
            with self.subTest(result=result.returncode), mock.patch.object(self.guard.subprocess, "run", return_value=result):
                with self.assertRaises(self.guard.ProbeUnavailable):
                    self.probe.command(["/bin/launchctl", "print", "gui/501"])
        with mock.patch.object(self.guard.subprocess, "run", side_effect=subprocess.TimeoutExpired("launchctl", 10)):
            with self.assertRaises(subprocess.TimeoutExpired):
                self.probe.command(["/bin/launchctl", "print", "gui/501"])

    def test_metadata_and_dangling_paths_do_not_become_absence(self):
        missing = self.directory / "absent parent/resource"
        self.assertFalse(self.probe.exists(missing))
        broken = self.directory / "broken"
        broken.symlink_to(self.directory / "not-present")
        self.assertTrue(self.probe.exists(broken))
        with self.assertRaises(self.guard.ProbeUnavailable):
            self.probe.exists(broken / "resource")
        bundle = self.directory / "App with spaces.app"
        contents = bundle / "Contents"
        contents.mkdir(parents=True)
        plist = contents / "Info.plist"
        for metadata in ({"CFBundleIdentifier": BUNDLE_ID}, {}, []):
            with plist.open("wb") as stream:
                plistlib.dump(metadata, stream)
            if metadata == {"CFBundleIdentifier": BUNDLE_ID}:
                self.assertEqual(self.probe.bundle_identifier(bundle), BUNDLE_ID)
            else:
                with self.assertRaises(self.guard.ProbeUnavailable):
                    self.probe.bundle_identifier(bundle)
        plist.write_text("malformed plist")
        with self.assertRaises(Exception):
            self.probe.bundle_identifier(bundle)

    def process_fixture(self, snapshot, paths, failures=None):
        failures = failures or {}

        def pidpath(pid, buffer, size):
            if pid in failures:
                ctypes.set_errno(failures[pid])
                return 0
            buffer.value = os.fsencode(paths[pid])
            return len(buffer.value)

        libproc = mock.Mock(proc_pidpath=FunctionStub(pidpath))
        return mock.patch.object(self.probe, "command", return_value=snapshot), mock.patch.object(self.guard.ctypes, "CDLL", return_value=libproc)

    def test_process_identity_uses_pidpath_bundle_id_and_preserves_spaces(self):
        executable = self.directory / "renamed with spaces.app/Contents/MacOS/not-the-display-name"
        executable.parent.mkdir(parents=True)
        with (executable.parent.parent / "Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": BUNDLE_ID}, stream)
        command_patch, lib_patch = self.process_fixture("123 501 misleading comm\n999 0 ignored\n", {123: executable})
        with command_patch, lib_patch:
            self.assertEqual(list(self.probe.processes()), [self.guard.RunningProcess(123, executable, BUNDLE_ID)])

    def test_process_probe_errors_are_unknown_except_positive_exit(self):
        for error, expected in [(errno.ESRCH, []), (errno.EPERM, None), (0, None)]:
            with self.subTest(error=error):
                command_patch, lib_patch = self.process_fixture("123 501 name\n", {}, {123: error})
                with command_patch, lib_patch:
                    if expected is not None:
                        self.assertEqual(list(self.probe.processes()), expected)
                    else:
                        with self.assertRaises(self.guard.ProbeUnavailable):
                            list(self.probe.processes())
        for snapshot in ("", "bad pid row", "1 0 /sbin/launchd\n"):
            with self.subTest(snapshot=snapshot):
                command_patch, lib_patch = self.process_fixture(snapshot, {})
                with command_patch, lib_patch, self.assertRaises(self.guard.ProbeUnavailable):
                    list(self.probe.processes())
        command_patch, lib_patch = self.process_fixture("123 501 name\n", {123: "/temporary/UsageButlerNetworkAgent"})
        with command_patch, lib_patch, self.assertRaises(self.guard.ProbeUnavailable):
            list(self.probe.processes())

    def test_cached_ownership_preferences_are_read_only_and_false_still_blocks(self):
        for present in (False, True):
            with self.subTest(present=present):
                reads, releases = [], []
                cf = mock.Mock()
                cf.CFStringCreateWithCString = FunctionStub(lambda allocator, value, encoding: value)
                cf.CFPreferencesCopyAppValue = FunctionStub(lambda key, domain: reads.append((key, domain)) or (17 if present else None))
                cf.CFRelease = FunctionStub(lambda value: releases.append(value))
                with mock.patch.object(self.guard.ctypes, "CDLL", return_value=cf):
                    self.assertEqual(self.probe.cached_preferences_present(), present)
                self.assertEqual(reads[0], (b"network.backgroundHistory.enabled", BUNDLE_ID.encode()))
                self.assertIn(BUNDLE_ID.encode(), releases)
                if present:
                    self.assertIn(17, releases)
                else:
                    self.assertEqual(len(reads), 2)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--fixture-probe":
        sys.exit(fixture_probe(sys.argv[2:]))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--script", type=Path, default=SCRIPT)
    arguments, remainder = parser.parse_known_args()
    SCRIPT = arguments.script.resolve(strict=True)
    output_parent = ROOT / ".build/debug-launch-guard-tests"
    output_parent.mkdir(parents=True, exist_ok=True)
    OUTPUT = Path(tempfile.mkdtemp(prefix="run ", dir=output_parent))
    print(f"OFFLINE_RESULTS={OUTPUT}", flush=True)
    unittest.main(argv=[sys.argv[0], *remainder], verbosity=2)
