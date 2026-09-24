#!/usr/bin/env python3
"""Run Radxa realm measurements and save CSVs on the host."""

import argparse
import csv
import os
import queue
import re
import signal
import socket
import subprocess
import threading
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent
HOME = ROOT.parent
DISKS = HOME / "disks"
QEMU = HOME / "qemu-system-aarch64"
KERNEL = DISKS / "Image"
SIZES = (65536, 262144, 524288, 1048576, 10485760)
LINKS = {"shm1": ("realm1", "realm2"), "shm2": ("realm2", "realm3"),
         "shm3": ("realm1", "realm3")}
POLICIES = {
    1: {"realm1": "realm1-one.json"},
    2: {"realm1": "realm1-two.json", "realm2": "realm2-two.json"},
    3: {"realm1": "realm1-three.json", "realm2": "realm2-three.json",
        "realm3": "realm3-three.json"},
}
MEASURE = "/root/microbenchmark/measure.sh"


def csv_append(path, fieldnames, row):
    new = not path.exists()
    with path.open("a", newline="", encoding="utf-8") as out:
        writer = csv.DictWriter(out, fieldnames=fieldnames)
        if new:
            writer.writeheader()
        writer.writerow(row)


class Realm:
    def __init__(self, name, links, protected, trial_dir, shm_dir):
        self.name = name
        self.links = links
        self.protected = protected
        self.trial_dir = trial_dir
        self.shm_dir = shm_dir
        self.socket_path = Path("/tmp") / f"mb-{os.getpid()}-{name}.sock"
        self.lines = queue.Queue()
        self.process = None
        self.sock = None
        self.log = None
        self.boot_ns = None
        args = [str(QEMU), "-M", "confidential-guest-support=rme0",
                "-object", "rme-guest,id=rme0,measurement-log=on,measurement-algorithm=sha512",
                "-nodefaults", "-kernel", str(KERNEL),
                "-chardev", f"socket,id=console,path={self.socket_path},server=on,wait=off",
                "-device", "virtio-serial-pci", "-device", "virtconsole,chardev=console",
                "-monitor", "none", "-serial", "none", "-display", "none",
                "-drive", f"if=none,file={DISKS / (name + '.img')},format=raw,id=hd0",
                "-device", "virtio-blk-pci,drive=hd0"]
        for index, link in enumerate(links, 1):
            args += ["-object", f"memory-backend-file,size=64M,share=on,mem-path={shm_dir / link},id={link}",
                     "-device", f"ivshmem-plain,memdev={link}" + (",protected=true" if protected else "")]
        args += ["-cpu", "host", "-M", "virt", "-enable-kvm",
                 "-M", "gic-version=3,its=on", "-smp", "1", "-m", "256M",
                 "-append", f"root=/dev/vda1 rw console=hvc0 {name}"]
        self.args = args

    def start(self, timeout):
        self.log = (self.trial_dir / f"{self.name}.log").open("w", encoding="utf-8")
        started = time.monotonic_ns()
        self.process = subprocess.Popen(self.args, stdout=self.log, stderr=subprocess.STDOUT,
                                        start_new_session=True)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError(f"{self.name} QEMU exited early; see {self.log.name}")
            try:
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.connect(str(self.socket_path))
                break
            except (FileNotFoundError, ConnectionRefusedError):
                self.sock.close()
                time.sleep(0.25)
        else:
            raise TimeoutError(f"{self.name} console socket did not appear")
        threading.Thread(target=self._read_console, daemon=True).start()
        self._until(lambda line: line.strip().endswith("MB_READY"), deadline)
        self.boot_ns = time.monotonic_ns() - started
        # The readiness unit and autologin shell start in the same boot stage.
        time.sleep(1)
        self.command("true", timeout=10)

    def _read_console(self):
        pending = ""
        with (self.trial_dir / f"{self.name}.console.log").open("w", encoding="utf-8") as log:
            while True:
                try:
                    data = self.sock.recv(65536)
                except OSError:
                    break
                if not data:
                    break
                pending += data.decode("utf-8", "replace").replace("\r", "")
                while "\n" in pending:
                    line, pending = pending.split("\n", 1)
                    log.write(line + "\n")
                    log.flush()
                    self.lines.put(line)
            self.lines.put(None)

    def _until(self, predicate, deadline):
        output = []
        while time.monotonic() < deadline:
            try:
                line = self.lines.get(timeout=min(1, max(0.01, deadline - time.monotonic())))
            except queue.Empty:
                if self.process.poll() is not None:
                    raise RuntimeError(f"{self.name} QEMU exited; see console log")
                continue
            if line is None:
                raise RuntimeError(f"{self.name} console closed")
            output.append(line)
            if predicate(line):
                return output
        raise TimeoutError(f"{self.name} command timed out")

    def send(self, command):
        marker = uuid.uuid4().hex
        # Commands are fixed by this program. No user text is passed to the shell.
        self.sock.sendall((f"{command}; mb_rc=$?; printf 'MB_DONE:{marker}:%s\\n' \"$mb_rc\"\n").encode())
        return marker

    def finish(self, marker, timeout):
        done = re.compile(rf"MB_DONE:{marker}:(\d+)\b")
        lines = self._until(lambda line: bool(done.search(line)),
                            time.monotonic() + timeout)
        match = done.search(lines[-1])
        if not match or int(match.group(1)) != 0:
            raise RuntimeError(f"{self.name} command failed: {lines[-5:]}")
        return lines

    def command(self, command, timeout=60):
        return self.finish(self.send(command), timeout)

    def stop(self):
        if self.process and self.process.poll() is None:
            try:
                self.command("poweroff", timeout=5)
            except Exception:
                pass
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGTERM)
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(self.process.pid, signal.SIGKILL)
                    self.process.wait()
        if self.sock:
            self.sock.close()
        if self.log:
            self.log.close()
        try:
            self.socket_path.unlink()
        except FileNotFoundError:
            pass


def result_value(lines, name):
    for line in lines:
        if "MB_RESULT " in line:
            match = re.search(rf"\b{name}=(\d+)\b", line)
            if match:
                return int(match.group(1))
    raise RuntimeError(f"Missing {name} in guest result")


def start_group(names, protected, trial_dir, timeout):
    shm_dir = Path("/dev/shm") / f"microbenchmark-{os.getpid()}-{trial_dir.name}"
    shm_dir.mkdir(exist_ok=True)
    for link, endpoints in LINKS.items():
        if all(name in names for name in endpoints):
            with (shm_dir / link).open("wb") as out:
                out.truncate(64 * 1024 * 1024)
    realms = {}
    try:
        for name in names:
            links = [link for link, endpoints in LINKS.items()
                     if name in endpoints and all(item in names for item in endpoints)]
            realm = Realm(name, links, protected, trial_dir, shm_dir)
            realms[name] = realm
            realm.start(timeout)
        return realms
    except BaseException:
        for realm in realms.values():
            realm.stop()
        raise


def stop_group(realms):
    for realm in reversed(list(realms.values())):
        realm.stop()
    if realms:
        shm_dir = next(iter(realms.values())).shm_dir
        for path in shm_dir.iterdir():
            path.unlink()
        shm_dir.rmdir()


def prepare_policies(realms, count):
    for name, realm in realms.items():
        for index in range(1, len(realm.links) + 1):
            realm.command(f"{MEASURE} prefault {index}", timeout=60)
        policy = f"/root/microbenchmark/configs/{POLICIES[count][name]}"
        lines = realm.command(f"{MEASURE} policy {policy}", timeout=60)
        realm.policy_ns = result_value(lines, "policy_upload_ns")


def run_attestation(args, results):
    fields = ["case", "trial", "realm", "boot_ns", "policy_upload_ns",
              "attestation_ns", "token_bytes", "status"]
    cases = [("one", ["realm1"], True),
             ("one_no_policy", ["realm1"], False),
             ("two", ["realm1", "realm2"], True),
             ("three", ["realm1", "realm2", "realm3"], True)]
    for case, names, policy in cases:
        for trial in range(1, args.trials + 1):
            trial_dir = results / f"attestation-{case}-{trial}"
            trial_dir.mkdir(exist_ok=True)
            realms = {}
            try:
                realms = start_group(names, policy, trial_dir, args.boot_timeout)
                if policy:
                    prepare_policies(realms, len(names))
                for name, realm in realms.items():
                    lines = realm.command(f"{MEASURE} attest", timeout=args.command_timeout)
                    csv_append(results / "attestation.csv", fields, {
                        "case": case, "trial": trial, "realm": name,
                        "boot_ns": realm.boot_ns,
                        "policy_upload_ns": getattr(realm, "policy_ns", ""),
                        "attestation_ns": result_value(lines, "attestation_ns"),
                        "token_bytes": result_value(lines, "token_bytes"),
                        "status": "ok"})
            except Exception as exc:
                print(f"attestation {case} trial {trial}: {exc}", flush=True)
                csv_append(results / "attestation.csv", fields, {
                    "case": case, "trial": trial, "realm": "", "boot_ns": "",
                    "policy_upload_ns": "", "attestation_ns": "",
                    "token_bytes": "", "status": str(exc)})
            finally:
                stop_group(realms)


def run_communication(args, results):
    fields = ["mode", "trial", "size_bytes", "iters", "total_ns", "avg_ns",
              "avg_us", "avg_ms", "filtered_total_ns", "filtered_avg_ns",
              "retry_noise_ns", "retry_miss_count", "status"]
    names = ["realm1", "realm2"]
    for mode in ("plain", "cbc", "ctr"):
        for trial in range(1, args.trials + 1):
            trial_dir = results / f"communication-{mode}-{trial}"
            trial_dir.mkdir(exist_ok=True)
            realms = {}
            try:
                realms = start_group(names, mode == "plain", trial_dir,
                                     args.boot_timeout)
                if mode == "plain":
                    prepare_policies(realms, 2)
                sizes = ",".join(map(str, SIZES))
                receiver = realms["realm2"]
                sender = realms["realm1"]
                recv_mark = receiver.send(
                    f"{MEASURE} communication realm2 {mode} {args.iters} {sizes}")
                time.sleep(1)
                lines = sender.command(
                    f"{MEASURE} communication realm1 {mode} {args.iters} {sizes}",
                    timeout=args.command_timeout)
                receiver.finish(recv_mark, args.command_timeout)
                begin = next(i for i, line in enumerate(lines)
                             if "MB_CSV_BEGIN " in line)
                end = next(i for i, line in enumerate(lines)
                           if line.strip() == "MB_CSV_END" and i > begin)
                rows = list(csv.DictReader(lines[begin + 1:end]))
                if len(rows) != len(SIZES):
                    raise RuntimeError("Guest returned an incomplete CSV")
                for row in rows:
                    row.update(mode=mode, trial=trial, status="ok")
                    csv_append(results / "communication.csv", fields, row)
            except Exception as exc:
                print(f"communication {mode} trial {trial}: {exc}", flush=True)
                csv_append(results / "communication.csv", fields, {
                    "mode": mode, "trial": trial, "size_bytes": "", "iters": "",
                    "total_ns": "", "avg_ns": "", "avg_us": "", "avg_ms": "",
                    "filtered_total_ns": "", "filtered_avg_ns": "",
                    "retry_noise_ns": "", "retry_miss_count": "", "status": str(exc)})
            finally:
                stop_group(realms)


def plot(results):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from collections import defaultdict
    from statistics import mean

    plots = results / "plots"
    plots.mkdir(exist_ok=True)
    path = results / "attestation.csv"
    if path.exists():
        values = defaultdict(list)
        with path.open(newline="", encoding="utf-8") as inp:
            for row in csv.DictReader(inp):
                if row["status"] == "ok":
                    values[(row["case"], "boot")].append(int(row["boot_ns"]) / 1e6)
                    values[(row["case"], "attestation")].append(int(row["attestation_ns"]) / 1e6)
                    if row["policy_upload_ns"]:
                        values[(row["case"], "policy")].append(int(row["policy_upload_ns"]) / 1e6)
        if values:
            cases = ["one", "one_no_policy", "two", "three"]
            fig, ax = plt.subplots(figsize=(9, 4))
            for offset, metric in ((-0.25, "boot"), (0, "policy"), (0.25, "attestation")):
                ax.bar([i + offset for i in range(len(cases))],
                       [mean(values[(case, metric)]) if values[(case, metric)] else 0 for case in cases],
                       width=0.24, label=metric)
            ax.set_xticks(range(len(cases)), cases)
            ax.set_ylabel("Mean duration (ms)")
            ax.legend()
            fig.tight_layout()
            fig.savefig(plots / "attestation.png")
            plt.close(fig)
    path = results / "communication.csv"
    if path.exists():
        values = defaultdict(list)
        with path.open(newline="", encoding="utf-8") as inp:
            for row in csv.DictReader(inp):
                if row["status"] == "ok":
                    values[(row["mode"], int(row["size_bytes"]))].append(float(row["avg_ms"]))
        if values:
            fig, ax = plt.subplots(figsize=(8, 4))
            for mode in ("plain", "cbc", "ctr"):
                sizes = [size for size in SIZES if values[(mode, size)]]
                ax.plot([size / 1048576 for size in sizes],
                        [mean(values[(mode, size)]) for size in sizes],
                        marker="o", label=mode)
            ax.set_xlabel("Payload size (MiB)")
            ax.set_ylabel("Mean round-trip time (ms)")
            ax.legend()
            fig.tight_layout()
            fig.savefig(plots / "communication.png")
            plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("all", "attestation", "communication", "plot"))
    parser.add_argument("--trials", type=int, default=20)
    parser.add_argument("--iters", type=int, default=20, help="round trips per payload size")
    parser.add_argument("--boot-timeout", type=int, default=180)
    parser.add_argument("--command-timeout", type=int, default=1800)
    parser.add_argument("--results", type=Path, default=ROOT / "results")
    args = parser.parse_args()
    if args.trials < 1 or args.iters < 1:
        parser.error("--trials and --iters must be positive")
    args.results.mkdir(parents=True, exist_ok=True)
    if args.action in ("all", "attestation"):
        run_attestation(args, args.results)
    if args.action in ("all", "communication"):
        run_communication(args, args.results)
    if args.action in ("all", "plot"):
        plot(args.results)


if __name__ == "__main__":
    main()
