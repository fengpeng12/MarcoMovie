"""Bounded, observational CoreSimulator diagnostics for disposable CI hosts.

No device boot/install/erase/delete, service restart or system process termination.
Only an owned subprocess exceeding its deadline is stopped. An independent empty
device-set is created under the output directory; it is not used to run an app.
Diagnostic collection is not application or simulator runtime acceptance.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import subprocess
import sys
import time
import hashlib

LIMIT = 512 * 1024
SERVICE = "com.apple.CoreSimulator.CoreSimulatorService"


def filtered(text, mode=None):
    if mode == "processes":
        text = "\n".join(line for line in text.splitlines()
                         if "CoreSimulator" in line or "simdiskimaged" in line
                         or re.search(r"(?:Simulator\.app|simctl)(?:/|\s|$)", line))
    elif mode == "service":
        text = "\n".join(line for line in text.splitlines()
                         if re.match(r"\s*(?:state|path|program|pid|runs|last exit code|active count|type)\s*=", line)
                         or "Could not find service" in line or "Bad request" in line)
    # No shell/environment dump is requested. Do not persist unexpected secret
    # assignments if a tool emits them in an error or a service log message.
    return re.sub(r"(?i)\b(authorization|cookie|password|access_token|secret)\s*[:=]\s*[^\s,;]+", r"\1=[redacted]", text)


class Observations:
    def __init__(self, output, seconds=480):
        self.output = output
        self.started = time.monotonic()
        # Reserve ten seconds for stopping our command, flushing and the report.
        self.deadline = self.started + min(seconds, 470)
        self.records = []
        (output / "logs").mkdir(parents=True, exist_ok=True)

    def run(self, name, command, seconds=30, mode=None):
        remaining = self.deadline - time.monotonic()
        record = {"name": name, "command": list(map(str, command)), "started_after_seconds": round(time.monotonic() - self.started, 3)}
        self.records.append(record)
        if remaining < 0.2:
            record.update(status="skipped_total_deadline", elapsed_seconds=0)
            return record, ""
        timeout = max(0.1, min(float(seconds), 60.0, remaining))
        began = time.monotonic()
        try:
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            record["owned_command_pid"] = process.pid
            try:
                stdout, stderr = process.communicate(timeout=timeout)
                record.update(status="completed", exit_code=process.returncode)
            except subprocess.TimeoutExpired:
                # The command was started by this script. Never locate/kill a
                # simulator daemon, a user's app or another job's process.
                process.kill()
                try:
                    stdout, stderr = process.communicate(timeout=5)
                except subprocess.TimeoutExpired as error:
                    stdout, stderr = error.output or b"", error.stderr or b""
                    process.stdout.close();process.stderr.close()
                record.update(status="timeout", exit_code=process.returncode)
        except OSError as error:
            stdout, stderr = b"", str(error).encode()
            record.update(status="launch_error", error=type(error).__name__)
        record["elapsed_seconds"] = round(time.monotonic() - began, 3)
        record["timeout_seconds"] = timeout
        record["truncated"] = len(stdout) > LIMIT or len(stderr) > LIMIT
        text = filtered(stdout[:LIMIT].decode("utf-8", "replace"), mode)
        errors = filtered(stderr[:LIMIT].decode("utf-8", "replace"), mode)
        (self.output / "logs" / (name + ".txt")).write_text(text + ("\nSTDERR:\n" + errors if errors else ""), encoding="utf-8")
        return record, text


def runtime_files():
    """Read bounded known runtime metadata without CoreSimulator APIs."""
    roots = [Path("/Library/Developer/CoreSimulator/Profiles/Runtimes"),
             Path.home() / "Library/Developer/CoreSimulator/Profiles/Runtimes"]
    volume_root = Path("/Library/Developer/CoreSimulator/Volumes")
    if volume_root.is_dir():
        roots += [p / "Library/Developer/CoreSimulator/Profiles/Runtimes" for p in sorted(volume_root.iterdir())[:16] if p.is_dir()]
    results = []
    for root in roots:
        for runtime in sorted(root.glob("*.simruntime"))[:16]:
            info = runtime / "Contents/Info.plist"
            item = {"path": str(runtime)}
            try:
                if info.stat().st_size > 1024 * 1024:
                    raise ValueError("Runtime plist exceeds budget")
                value = plistlib.loads(info.read_bytes())
                item["info"] = {key: value[key] for key in ("CFBundleIdentifier", "CFBundleVersion", "CFBundleShortVersionString", "Version", "Build") if key in value}
            except (OSError, ValueError, plistlib.InvalidFileException) as error:
                item["error"] = type(error).__name__
            results.append(item)
    return results


def self_test(output):
    output.mkdir(parents=True, exist_ok=True)
    observations = Observations(output, 5)
    ok, text = observations.run("owned_output", [sys.executable, "-c", "print('owned fixture')"], 1)
    assert ok["exit_code"] == 0 and text.strip() == "owned fixture"
    timeout, _ = observations.run("owned_timeout", [sys.executable, "-c", "import time;time.sleep(2)"], 0.15)
    assert timeout["status"] == "timeout" and timeout["elapsed_seconds"] < 2
    assert filtered("123 CoreSimulator\n456 OtherApp", "processes") == "123 CoreSimulator"
    assert filtered("  pid = 123\n  environment = SECRET\n  state = running", "service") == "  pid = 123\n  state = running"
    assert "value123" not in filtered("Authorization: value123")
    observations.deadline = time.monotonic() - 1
    skipped, _ = observations.run("skipped", ["this-command-must-not-run"])
    assert skipped["status"] == "skipped_total_deadline"
    result = {"host_self_checks": 6, "passed": True, "simulator_exercised": False, "observations": observations.records}
    (output / "self-test-result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps({key: value for key, value in result.items() if key != "observations"}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--runtime-files", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.runtime_files:
        print(json.dumps(runtime_files(), ensure_ascii=False, indent=2));return
    if args.self_test:
        self_test(args.output_dir.resolve());return
    if sys.platform != "darwin":
        raise SystemExit("Observational simulator diagnostics require macOS; --self-test is host-only")
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    observations = Observations(output)
    report = {"diagnostics_collected": False, "application_executed": False, "runtime_accepted": False,
              "github_sha": os.environ.get("GITHUB_SHA"), "github_run_id": os.environ.get("GITHUB_RUN_ID"),
              "image_version": os.environ.get("ImageVersion"), "runner_arch": os.environ.get("RUNNER_ARCH"),
              "host_arch": platform.machine(), "host_platform": platform.platform(),
              "script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), "observations": observations.records,
              "scope": "Observation only; no running app, device cleanup, service restart or acceptance."}
    try:
        for name, command in (
            ("developer_directory", ["xcode-select", "-p"]),
            ("xcode_version", ["xcodebuild", "-version"]),
            ("simctl_binary", ["xcrun", "--find", "simctl"]),
            ("simulator_sdk", ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"]),
            ("sdk_inventory", ["xcodebuild", "-showsdks"]),
            ("host_resources", ["sysctl", "hw.ncpu", "hw.memsize", "vm.loadavg"]),
        ):
            observations.run(name, command, 20)
        observations.run("runtime_files", [sys.executable, str(Path(__file__).resolve()), "--output-dir", str(output), "--runtime-files"], 30)
        service = "gui/" + str(os.getuid()) + "/" + SERVICE
        observations.run("service_before", ["launchctl", "print", service], 10, "service")
        observations.run("processes_before", ["ps", "-axo", "pid,ppid,etime,%cpu,%mem,comm"], 10, "processes")
        cold, cold_text = observations.run("default_devices_first", ["xcrun", "simctl", "list", "devices", "available", "--json"], 60)
        empty = output / "owned-empty-device-set"
        empty.mkdir(exist_ok=False)
        observations.run("independent_empty_set", ["xcrun", "simctl", "--set", str(empty), "list", "devices", "available", "--json"], 60)
        observations.run("runtime_inventory", ["xcrun", "simctl", "list", "runtimes", "--json"], 60)
        warm, warm_text = observations.run("default_devices_second", ["xcrun", "simctl", "list", "devices", "available", "--json"], 60)
        observations.run("service_after", ["launchctl", "print", service], 10, "service")
        observations.run("processes_after", ["ps", "-axo", "pid,ppid,etime,%cpu,%mem,comm"], 10, "processes")
        observations.run("simulator_service_log", ["log", "show", "--last", "3m", "--style", "compact",
            "--predicate", 'process == "com.apple.CoreSimulator.CoreSimulatorService" OR process == "simdiskimaged"'], 25)
        for name, record, text in (("first", cold, cold_text), ("second", warm, warm_text)):
            try:
                data = json.loads(text) if record.get("exit_code") == 0 else {}
                report[name + "_available_ios_devices"] = sum(1 for runtime, devices in data.get("devices", {}).items()
                    if ".iOS-" in runtime for device in devices if device.get("isAvailable"))
            except (ValueError, TypeError):
                report[name + "_available_ios_devices"] = None
        report["diagnostics_collected"] = True
    finally:
        report["elapsed_seconds"] = round(time.monotonic() - observations.started, 3)
        (output / "diagnostics.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps({"output": str(output), "diagnostics_collected": report["diagnostics_collected"],
                          "application_executed": False, "observations": len(observations.records)}, indent=2))


if __name__ == "__main__":
    main()
