#!/usr/bin/env python3
"""Controlled two-protocol loopback check of the shipping Swift source."""
import json
import csv
import io
import os
import pathlib
import pty
import select
import socket
import subprocess
import sys
import threading
import time

probe, sender, destination = sys.argv[1:]
process_environment = {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C", "TERM": "dumb"}
out = pathlib.Path(destination)
out.mkdir(exist_ok=False, parents=True)
tcp = socket.socket()
tcp.bind(("127.0.0.1", 0))
tcp.listen(1)
udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
udp.bind(("127.0.0.1", 0))
tcp.settimeout(35)
udp.settimeout(35)
server = {"tcp_received": 0, "tcp_sent": 0, "udp_received": 0, "udp_sent": 0}
failures = []
def serve_tcp():
    try:
        conn, _ = tcp.accept()
        with conn:
            conn.settimeout(35)
            while server["tcp_received"] < 8388608:
                part = conn.recv(65536)
                if not part:
                    raise RuntimeError("premature EOF")
                server["tcp_received"] += len(part)
            conn.sendall(b"d" * 2097152)
            server["tcp_sent"] = 2097152
            # Keep the accepted socket open until the observed sender closes.
            while conn.recv(1):
                pass
    except Exception as error:
        failures.append(type(error).__name__)
def serve_udp():
    try:
        for _ in range(512):
            payload, address = udp.recvfrom(2048)
            server["udp_received"] += len(payload)
            server["udp_sent"] += udp.sendto(b"d" * 64, address)
    except Exception as error:
        failures.append(type(error).__name__)
threads = [threading.Thread(target=serve_tcp), threading.Thread(target=serve_udp)]
for thread in threads:
    thread.start()
child = subprocess.Popen([sender, str(tcp.getsockname()[1]), str(udp.getsockname()[1])],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         close_fds=True, env=process_environment)
assert child.stdout.readline().decode().strip() == "ready " + str(child.pid)
# A separately observed, PID-filtered system counter is diagnostic evidence,
# not an alternative source for the application. Preserve discrepancies.
raw_master, raw_slave = pty.openpty()
raw_arguments = ["/usr/bin/nettop", "-P", "-p", str(child.pid), "-L", "18", "-n", "-x", "-s", "1",
                 "-J", "bytes_in,bytes_out,rx_dupe,re-tx"]
raw = subprocess.Popen(raw_arguments, stdout=raw_slave, stderr=subprocess.DEVNULL, stdin=raw_slave,
                       close_fds=True, env=process_environment)
os.close(raw_slave)
raw_bytes = bytearray()
raw_baseline_ready = threading.Event()
def drain_raw():
    pending = b""
    while raw.poll() is None:
        if select.select([raw_master], [], [], 0.2)[0]:
            try:
                part = os.read(raw_master, 16384)
            except OSError:
                break
            if not part:
                break
            if len(raw_bytes) + len(part) <= 1048576:
                raw_bytes.extend(part)
            pending += part
            while b"\n" in pending:
                line, pending = pending.split(b"\n", 1)
                if line.split(b",", 1)[0].endswith(("." + str(child.pid)).encode()):
                    raw_baseline_ready.set()
            if len(pending) > 65536:
                raise RuntimeError("unbounded diagnostic row")
raw_thread = threading.Thread(target=drain_raw)
raw_thread.start()
source = subprocess.Popen([probe, str(child.pid), "12"], stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, close_fds=True, text=True, env=process_environment)
records = []
nettop_pids = set()
sent = False
complete_baselines = 0
started = time.monotonic()
try:
    for line in source.stdout:
        record = json.loads(line)
        record["controllerElapsedSeconds"] = time.monotonic() - started
        records.append(record)
        listing = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid=,comm="], text=True, env=process_environment)
        for process_line in listing.splitlines():
            fields = process_line.strip().split(None, 2)
            if len(fields) == 3 and fields[1] == str(source.pid) and fields[2] == "/usr/bin/nettop":
                nettop_pids.add(int(fields[0]))
        if record.get("cycle") == 1 and record.get("sequence"):
            complete_baselines = complete_baselines + 1 if record.get("complete") and record.get("matched") else 0
        if not sent and record.get("cycle") == 1 and complete_baselines >= 2 and raw_baseline_ready.is_set():
            child.stdin.write(b"g")
            child.stdin.flush()
            sent = True
    source.wait(timeout=5)
    assert source.returncode == 0, source.stderr.read()
    assert sent
    assert child.stdout.readline().strip() == b"complete"
    child.stdin.write(b"q")
    child.stdin.flush()
    child.wait(timeout=5)
    for thread in threads:
        thread.join(timeout=5)
    if raw.poll() is None:
        raw.terminate()
    raw.wait(timeout=5)
    raw_thread.join(timeout=5)
    raw_rows = []
    for values in csv.reader(io.StringIO(raw_bytes.decode("utf-8", errors="replace"))):
        if len(values) >= 5 and values[0].endswith("." + str(child.pid)):
            raw_rows.append(dict(zip(["process", "download", "upload", "rx_dupe", "re-tx"], values[:5])))
    raw_delta = {key: int(raw_rows[-1][key]) - int(raw_rows[0][key])
                 for key in ["upload", "download", "rx_dupe", "re-tx"]} if len(raw_rows) >= 2 else None
    live = subprocess.check_output(["/bin/ps", "-axo", "pid="], text=True, env=process_environment)
    alive = set(map(int, live.split()))
    samples = [r for r in records if r.get("cycle") == 1 and r.get("matched")]
    delta = {direction: int(samples[-1][direction]) - int(samples[0][direction])
             for direction in ["upload", "download"]}
    expected = {"upload": 8388608 + 524288, "download": 2097152 + 32768}
    receipt = {"source": "shipping NettopProcessSource + ProcessNetworkAggregator",
               "protocols": ["TCP IPv4 loopback", "UDP IPv4 loopback"],
               "senderPID": child.pid, "sourcePID": source.pid, "childExit": child.returncode,
               "server": server, "expected": expected, "observedDelta": delta,
               "exactOnThisRun": expected == delta, "failures": failures,
               "systemDiagnostic": {"arguments": raw_arguments, "pid": raw.pid,
                                    "delta": raw_delta, "rows": raw_rows},
               "ownedNettopPIDs": sorted(nettop_pids), "ownedNettopRemaining": sorted(nettop_pids & alive),
               "records": records,
               "limitations": ["single host", "socket counter semantics are not a universal payload equality promise",
                               "no actual sleep, VPN changes, external network or production Provider calls"]}
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({k: v for k, v in receipt.items() if k != "records"}, indent=2))
finally:
    for process in [source, child, raw]:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)
    tcp.close()
    udp.close()
    raw_thread.join(timeout=2)
    os.close(raw_master)
