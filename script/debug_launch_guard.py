#!/usr/bin/env python3
"""Read-only, fail-closed preflight for the production-identity Debug launcher.

No bundle generation, signing, process signals, preference writes, database
opens, service registration or cleanup occurs here. This is a bounded check,
not an isolated runtime or a system-wide lock against concurrent launches.
"""

import argparse
import ctypes
import errno
import os
from pathlib import Path
import plistlib
import pwd
import re
import subprocess
import sys
from typing import NamedTuple, Optional


BUNDLE_ID = "io.github.obisoldbee.UsageButler"
SERVICE_LABEL = BUNDLE_ID + ".network-agent"
EXECUTABLE_NAMES = {"Usage-Butler", "UsageButlerNetworkAgent"}


class RunningProcess(NamedTuple):
    pid: int
    executable: Path
    bundle_identifier: Optional[str]


class ProbeUnavailable(RuntimeError):
    pass


class NativeProbe:
    def __init__(self):
        if sys.platform != "darwin":
            raise ProbeUnavailable("macOS process/service probes are unavailable")
        self.uid = os.getuid()
        # Do not trust an overridden HOME to select another preferences/DB domain.
        self.home = Path(pwd.getpwuid(self.uid).pw_dir).resolve(strict=True)
        if Path(os.environ.get("HOME", str(self.home))).resolve() != self.home:
            raise ProbeUnavailable("HOME differs from the current user's home directory")

    @staticmethod
    def exists(path):
        try:
            path.lstat()  # Broken links are occupied/unknown, never a clean absence.
            return True
        except FileNotFoundError:
            # A dangling parent link must not hide shared resources.
            for parent in path.parents:
                if parent.is_symlink() and not parent.exists():
                    raise ProbeUnavailable("a resource parent is a dangling link")
                try:
                    parent.stat()
                except FileNotFoundError:
                    continue
                if not parent.is_dir() or not os.access(parent, os.R_OK | os.X_OK):
                    raise ProbeUnavailable("a resource parent cannot be inspected")
                return False
            raise ProbeUnavailable("resource absence could not be established")

    @staticmethod
    def bundle_identifier(bundle):
        plist = bundle / "Contents/Info.plist"
        if plist.stat().st_size > 1024 * 1024:
            raise ProbeUnavailable("bundle metadata exceeds the probe limit")
        with plist.open("rb") as stream:
            metadata = plistlib.load(stream)
        if not isinstance(metadata, dict):
            raise ProbeUnavailable("bundle metadata is not a dictionary")
        identifier = metadata.get("CFBundleIdentifier")
        if not isinstance(identifier, str) or not identifier:
            raise ProbeUnavailable("bundle identity is missing")
        return identifier

    @staticmethod
    def cached_preferences_present():
        # cfprefsd may hold these ownership keys before a plist reaches disk.
        # Query only these two keys; do not synchronize/write or read credentials.
        cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
        cf.CFStringCreateWithCString.restype = ctypes.c_void_p
        cf.CFPreferencesCopyAppValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        cf.CFPreferencesCopyAppValue.restype = ctypes.c_void_p
        cf.CFRelease.argtypes = [ctypes.c_void_p]
        cf.CFRelease.restype = None
        domain = cf.CFStringCreateWithCString(None, BUNDLE_ID.encode(), 0x08000100)
        if not domain:
            raise ProbeUnavailable("preferences domain could not be created")
        try:
            for name in ("network.backgroundHistory.enabled", "network.backgroundHistory.registeredCode"):
                key = cf.CFStringCreateWithCString(None, name.encode(), 0x08000100)
                if not key:
                    raise ProbeUnavailable("preferences key could not be created")
                try:
                    value = cf.CFPreferencesCopyAppValue(key, domain)
                    if value:
                        cf.CFRelease(value)
                        return True  # Even false is existing production-domain state.
                finally:
                    cf.CFRelease(key)
            return False
        finally:
            cf.CFRelease(domain)

    @staticmethod
    def command(arguments):
        result = subprocess.run(arguments, text=True, capture_output=True, timeout=10)
        if result.returncode or result.stderr.strip():
            raise ProbeUnavailable("read-only " + Path(arguments[0]).name + " probe failed")
        return result.stdout

    def service_registered(self):
        label = re.compile(r"(?<![A-Za-z0-9_.-])" + re.escape(SERVICE_LABEL) + r"(?![A-Za-z0-9_.-])")
        for kind in ("gui", "user"):
            domain = f"{kind}/{self.uid}"
            output = self.command(["/bin/launchctl", "print", domain])
            if not output.startswith(domain + " = {") or not output.rstrip().endswith("}") or "services = {" not in output:
                raise ProbeUnavailable("launchctl domain snapshot is incomplete")
            if label.search(output):
                return True  # Loaded, disabled or otherwise reserved: all block.
        return False

    def processes(self):
        output = self.command(["/bin/ps", "-ww", "-axo", "pid=,uid=,comm="])
        if not output.strip():
            raise ProbeUnavailable("process snapshot is empty")
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        libproc.proc_pidpath.restype = ctypes.c_int
        current_user_seen = False
        for line in output.splitlines():
            fields = line.split(None, 2)
            if len(fields) != 3 or not fields[0].isdecimal() or not fields[1].isdecimal():
                raise ProbeUnavailable("process snapshot is malformed")
            pid, uid = int(fields[0]), int(fields[1])
            if uid != self.uid:
                continue
            current_user_seen = True
            # ps comm is not an identity authority. Re-read the kernel's executable
            # for every current-user PID, including renamed Apps and helpers.
            buffer = ctypes.create_string_buffer(4096)
            ctypes.set_errno(0)
            count = libproc.proc_pidpath(pid, buffer, len(buffer))
            if count <= 0:
                if ctypes.get_errno() == errno.ESRCH:
                    continue  # Positive process-exited result, not a failed probe.
                raise ProbeUnavailable(f"PID {pid} executable path could not be verified")
            executable = Path(os.fsdecode(buffer.value))
            if not executable.is_absolute():
                raise ProbeUnavailable(f"PID {pid} executable path is not absolute")
            bundles = [parent for parent in executable.parents if parent.suffix.lower() == ".app"]
            identifier = None
            for bundle in bundles:
                bundle_id = self.bundle_identifier(bundle)
                if bundle_id == BUNDLE_ID:
                    identifier = bundle_id
                    break
                if identifier is None:
                    identifier = bundle_id
            if not bundles and executable.name in EXECUTABLE_NAMES:
                # An extracted/relocated product executable has no verifiable
                # containing bundle. Never classify it as a safe absence.
                raise ProbeUnavailable(f"PID {pid} product executable has no containing App")
            yield RunningProcess(pid, executable, identifier)
        if not current_user_seen:
            raise ProbeUnavailable("process snapshot does not contain the current user")


def check_launch(app_binary, probe):
    for bundle in (Path("/Applications/Usage-Butler.app"), probe.home / "Applications/Usage-Butler.app"):
        if probe.exists(bundle):
            identifier = probe.bundle_identifier(bundle)
            if identifier != BUNDLE_ID:
                raise ProbeUnavailable(f"installation path has unexpected bundle identity: {bundle}")
            return f"production installation exists: {bundle} (GUI exit does not release its resources)"
    paths = [probe.home / "Library/Preferences" / (BUNDLE_ID + ".plist"),
             probe.home / "Library/Application Support" / BUNDLE_ID / "NetworkHistory",
             probe.home / "Library/Application Support/Usage-Butler/quota-cache",
             probe.home / "Library/Application Support/Usage-Butler/memory-history"]
    for path in paths:
        if probe.exists(path):
            return f"existing production identity/resource domain: {path}"
    if probe.cached_preferences_present():
        return "production background preferences/registration binding already exist"
    if probe.service_registered():
        return f"production launchd service label is present: {SERVICE_LABEL}"
    expected = app_binary.resolve()
    for process in probe.processes():
        if process.bundle_identifier == BUNDLE_ID:
            # Only this build's exact main executable may be stopped/rebuilt.
            # A helper, even under this build, remains an independent owner.
            if process.executable.resolve() != expected or process.executable.name != "Usage-Butler":
                return f"production identity is running at PID {process.pid}: {process.executable}"
    return None


def main(arguments=None, probe=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-binary", type=Path, required=True)
    args = parser.parse_args(arguments)
    try:
        if not args.app_binary.is_absolute():
            raise ProbeUnavailable("candidate executable path must be absolute")
        reason = check_launch(args.app_binary, probe if probe is not None else NativeProbe())
    except Exception as error:
        # A new OS/parser/API failure must remain unknown, never clean absence.
        reason = "safety probe unavailable/unknown: " + str(error)
    if reason:
        print("Debug launch refused: " + reason, file=sys.stderr)
        print("Next: use script/test.sh for source-only validation, or run Debug in a clean disposable macOS environment with no production installation, service, preferences or history. Preserve existing data; use docs/background-service-upgrades.md for separately authorized formal upgrades.", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
