"""Run the destructive API 23 fixtures only on a disposable x86 Android TV emulator."""

from pathlib import Path
import json
import os
import re
import subprocess
import time


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "android/build/api23-probes"
ADB = os.environ.get("ADB", "adb")
PROBES = ("SubtitleProbe", "HomeProbe", "SourceHostProbe")


def adb(*args, check=True, timeout=300):
    return subprocess.run([ADB, *args], check=check, text=True, capture_output=True,
                          encoding="utf-8", errors="replace", timeout=timeout).stdout


def boot_ready(properties, windows):
    # Marshmallow can set sys.boot_completed in its encryption-only framework.
    # Wait for both encryption and the resumed CryptKeeper screen to disappear.
    focused = "\n".join(line for line in windows.splitlines()
                        if "mCurrentFocus" in line or "mFocusedApp" in line)
    return (properties.get("sys.boot_completed") == "1"
            and properties.get("init.svc.bootanim", "stopped") == "stopped"
            and properties.get("init.svc.encrypt") != "running"
            and properties.get("vold.encrypt_progress", "") in ("", "100")
            and properties.get("vold.decrypt", "") not in
            ("trigger_restart_min_framework", "trigger_shutdown_framework", "trigger_encryption")
            and "CryptKeeper" not in focused)


def wait_for_full_boot(timeout_seconds=600, stable_seconds=20):
    deadline = time.monotonic() + timeout_seconds
    stable_since = None
    prior_boot = None
    states = []
    try:
        while time.monotonic() < deadline:
            try:
                raw = adb("shell", "getprop", timeout=20)
                properties = dict(re.findall(r"^\[([^\]]+)\]: \[(.*)\]$", raw, re.MULTILINE))
                windows = adb("shell", "dumpsys", "window", "windows", timeout=20)
                boot = adb("shell", "cat", "/proc/sys/kernel/random/boot_id", timeout=20).strip()
                state = {key: properties.get(key, "") for key in
                         ("sys.boot_completed", "init.svc.encrypt", "vold.encrypt_progress", "vold.decrypt")}
                state["ready"] = boot_ready(properties, windows)
                if not states or state != states[-1]:
                    states.append(state)
                    print("Waiting for complete API 23 boot: " + json.dumps(state), flush=True)
                ready = (state["ready"] and bool(boot)
                         and "package:" in adb("shell", "pm", "path", "android", timeout=20))
                if ready:
                    if stable_since is None or boot != prior_boot:
                        stable_since = time.monotonic()
                    if time.monotonic() - stable_since >= stable_seconds:
                        return
                else:
                    stable_since = None
                prior_boot = boot
            except (subprocess.SubprocessError, OSError):
                stable_since = None
                prior_boot = None
            time.sleep(2)
        raise RuntimeError("API 23 encryption/full-framework boot did not stabilize")
    finally:
        with (OUT / "boot-readiness.log").open("a", encoding="utf-8") as log:
            log.write(json.dumps(states, indent=2) + "\n")


def main():
    (OUT / "boot-readiness.log").unlink(missing_ok=True)
    wait_for_full_boot()
    if adb("shell", "getprop", "ro.kernel.qemu").strip() != "1":
        raise RuntimeError("This destructive fixture is restricted to an emulator")
    if adb("shell", "getprop", "ro.build.version.sdk").strip() != "23":
        raise RuntimeError("API 23 is required to exercise the missing callback regression")
    if adb("shell", "getprop", "ro.product.cpu.abi").strip() != "x86":
        raise RuntimeError("The API 23 Android TV fixture includes only x86 QuickJS JNI")
    features = adb("shell", "pm", "list", "features")
    if "android.software.leanback" not in features:
        raise RuntimeError("An actual Android TV system image is required")
    display = adb("shell", "wm", "size")
    physical = re.search(r"Physical size:\s*(\d+)x(\d+)", display)
    if not physical or int(physical[1]) <= int(physical[2]) or "Override size" in display:
        raise RuntimeError("Use a landscape TV AVD/skin; do not resize a portrait framebuffer with wm")
    (OUT / "display.txt").write_text(display + adb("shell", "wm", "density"), encoding="utf-8")
    (OUT / "device.txt").write_text(adb("shell", "getprop"), encoding="utf-8")
    adb("install", "-r", str(OUT / "fixture.apk"))
    adb("install", "-r", str(OUT / "probe.apk"))
    # The AVD supplies the real landscape framebuffer. Never emulate it with wm overrides.
    adb("shell", "svc", "wifi", "disable")
    adb("shell", "svc", "data", "disable")
    results = {}
    failures = []
    try:
        for probe in PROBES:
            log = ""
            try:
                wait_for_full_boot(timeout_seconds=120, stable_seconds=4)
                adb("shell", "pm", "clear", "com.pilipala.marcomovie")
                adb("logcat", "-c")
                log = adb("shell", "am", "instrument", "-w",
                          "com.pilipala.marcomovie.test/com.pilipala.marcomovie." + probe)
                print(log)
                match = re.search(r"INSTRUMENTATION_STATUS: result=(\{[^\r\n]+\})", log)
                result = json.loads(match[1]) if match else {}
                results[probe] = result
                if result.get("passed") is not True:
                    raise RuntimeError(probe + " failed; see logs and screenshots")
            except Exception as error:
                failures.append(probe)
                results.setdefault(probe, {"passed": False})["runner_error"] = str(error)
                captured = getattr(error, "stdout", None)
                if captured and not log:
                    log = captured.decode("utf-8", errors="replace") if isinstance(captured, bytes) else captured
                print(probe + ": " + str(error))
            finally:
                (OUT / (probe + ".log")).write_text(log, encoding="utf-8")
                try:
                    (OUT / (probe + "-logcat.txt")).write_text(adb("logcat", "-d", check=False), encoding="utf-8")
                    (OUT / "screenshots" / probe).mkdir(parents=True, exist_ok=True)
                    adb("pull", "/sdcard/Android/data/com.pilipala.marcomovie/files/",
                        str(OUT / "screenshots" / probe), check=False)
                except Exception as error:
                    results.setdefault(probe, {})["evidence_error"] = str(error)
                    if probe not in failures:
                        failures.append(probe)
    finally:
        (OUT / "results.json").write_text(json.dumps(results, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    if failures:
        raise RuntimeError("API 23 regressions failed: " + ", ".join(failures))


if __name__ == "__main__":
    main()
