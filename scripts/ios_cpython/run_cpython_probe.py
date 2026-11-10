"""Experimental iOS CPython probe. Stage on any host; compile/run only on macOS.

No product files, provisioning profiles, accounts or remote source scripts are used.
Only this disposable simulator app may be terminated by the runner on a timeout.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
import zipfile

HERE = Path(__file__).resolve().parent
ARCHIVE = "Python-3.14-iOS-support.b14.tar.gz"
URL = "https://github.com/beeware/Python-Apple-support/releases/download/3.14-b14/" + ARCHIVE
SHA256 = "703ff822529f46edcbcd8b88096b2544f6990f3109ad38b4b4b61bb489a7c1ee"
IDENTIFIER = "com.pilipala.experimental.cpythonprobe"

REQUIRED_CHECKS = frozenset((
    "pinned_python_3_14_10", "io_utf8", "io_binary", "json_utf8", "hashlib_sha256",
    "os_path_local_file", "ssl_context", "certifi_trust_store", "bs4_html_parser_css",
    "spider_home", "spider_home_vod", "spider_category_pagination", "spider_search_chinese",
    "spider_detail_opaque_id", "spider_detail_episodes", "spider_play_parse",
    "synthetic_manifest_prefix", "requests_json", "requests_session_cookie",
    "requests_post_unicode", "requests_bs4_combined", "requests_bounded_read_timeout",
    "fixture_thread_joined", "cooperative_python_loop_timeout",
    "blocking_c_call_exceeds_trace_deadline", "isolated_interpreter_pure_dependencies",
    "main_interpreter_state_preserved", "ui_main_thread_remained_responsive",
    "host_sigpipe_ignored_before_python", "closed_pipe_returns_epipe",
    "python_preserves_host_signal_dispositions", "closed_socket_raises_broken_pipe",
    *("stdlib_extension_" + name for name in ("_socket", "_ssl", "_hashlib", "_json", "_elementtree", "pyexpat", "zlib", "_sqlite3")),
    *("ios_framework_" + name for name in ("_socket", "_ssl", "_hashlib", "_json", "_elementtree", "pyexpat", "zlib", "_sqlite3")),
))


def validate_app_report(report, arch):
    """Do not trust a single aggregate passed flag or duplicated check entries."""
    if not isinstance(report, dict) or report.get("passed") is not True:
        raise ValueError("App did not report successful native execution")
    if report.get("native_arch") != arch or not re.match(r"^3\.14\.10\s", str(report.get("runtime", ""))):
        raise ValueError("App architecture or actual Python version differs from pinned input")
    checks = report.get("checks")
    if not isinstance(checks, list) or not 40 <= len(checks) <= 256:
        raise ValueError("Insufficient or invalid native check inventory")
    names = set()
    for entry in checks:
        if not isinstance(entry, dict) or not isinstance(entry.get("name"), str) or not entry["name"]:
            raise ValueError("Malformed native check")
        if entry.get("passed") is not True or entry["name"] in names:
            raise ValueError("Failed or duplicated native check")
        names.add(entry["name"])
    if not REQUIRED_CHECKS.issubset(names):
        raise ValueError("Required native behavior checks are missing")
    fixture = report.get("fixture")
    if not isinstance(fixture, dict) or fixture.get("passed") is not True or fixture.get("platform") != "ios":
        raise ValueError("Fixture was not executed by iOS CPython")
    if not re.match(r"^3\.14\.10\s", str(fixture.get("runtime", ""))):
        raise ValueError("Fixture Python version differs from pinned input")
    lock = json.loads((HERE / "pure-dependencies.lock.json").read_text(encoding="utf-8"))
    if fixture.get("dependencies") != {package["name"]: package["version"] for package in lock["packages"]}:
        raise ValueError("Executed dependency versions differ from locked wheels")


def diagnostic_identity(identifier, app_name):
    if (identifier, app_name) not in (
        (IDENTIFIER, "CPythonProbe"),
        ("com.pilipala.experimental.cpythonflutter", "CPythonFlutterProbe"),
    ):
        raise ValueError("Diagnostics are restricted to the two owned experiment apps")


def collect_diagnostics(out, progress, start_time, identifier=IDENTIFIER, app_name="CPythonProbe"):
    """Collect only this disposable app's diagnostics, never other app logs."""
    diagnostic_identity(identifier, app_name)
    if sys.platform != "darwin":
        return
    folder = out / "diagnostics"
    folder.mkdir(exist_ok=True)
    crash_roots = [("host", Path.home() / "Library/Logs/DiagnosticReports")]
    if progress.get("simulator_udid"):
        crash_roots.append(("simulator", Path.home() / "Library/Developer/CoreSimulator/Devices"
                            / progress["simulator_udid"] / "data/Library/Logs/CrashReporter"))
    copied = 0
    for origin, crash_root in crash_roots:
        for source in sorted(crash_root.glob(app_name + "*")):
            if (source.is_file() and not source.is_symlink() and source.stat().st_mtime >= start_time - 5
                    and source.stat().st_size <= 5 * 1024 * 1024 and copied < 10):
                shutil.copyfile(source, folder / (origin + "-" + source.name))
                copied += 1
    if progress.get("simulator_udid"):
        log = folder / (app_name + "-unified.log")
        try:
            with log.open("w", encoding="utf-8") as output:
                subprocess.run(["xcrun", "simctl", "spawn", progress["simulator_udid"], "log", "show",
                                "--last", "5m", "--style", "compact", "--info", "--debug",
                                "--predicate", 'process == "' + app_name + '" OR eventMessage CONTAINS "' + identifier + '"'],
                               check=False, stdout=output, stderr=subprocess.STDOUT, text=True, timeout=25)
            if log.stat().st_size > 5 * 1024 * 1024:
                with log.open("rb") as source:
                    source.seek(-5 * 1024 * 1024, os.SEEK_END)
                    tail = source.read()
                log.write_bytes(b"[truncated to final 5 MiB]\n" + tail)
        except (OSError, subprocess.TimeoutExpired) as error:
            progress["diagnostics_note"] = type(error).__name__


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def checked_relative(value):
    path = PurePosixPath(value)
    if not value or "\\" in value or path.is_absolute() or ".." in path.parts or ":" in value:
        raise ValueError("Unsafe archive member path")
    return path


def download_verified(url, path, expected):
    path = Path(path)
    if not path.exists():
        with urllib.request.urlopen(url, timeout=90) as response:
            body = response.read(64 * 1024 * 1024 + 1)
        if len(body) > 64 * 1024 * 1024:
            raise ValueError("Download exceeds probe budget")
        if hashlib.sha256(body).hexdigest() != expected:
            raise ValueError("Downloaded artifact SHA-256 mismatch")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(body)
    if digest(path) != expected:
        raise ValueError("Cached artifact SHA-256 mismatch: " + path.name)
    return path


def stage_wheels(destination, cache):
    lock = json.loads((HERE / "pure-dependencies.lock.json").read_text(encoding="utf-8"))
    total = 0
    files = []
    for package in lock["packages"]:
        filename = package["file"]
        if "/" in filename or "\\" in filename or not filename.endswith("-none-any.whl"):
            raise ValueError("Probe only accepts the reviewed pure-Python wheels")
        if not package["url"].startswith("https://files.pythonhosted.org/"):
            raise ValueError("Unexpected wheel host")
        wheel = download_verified(package["url"], cache / "wheels" / filename, package["sha256"])
        with zipfile.ZipFile(wheel) as archive:
            for member in archive.infolist():
                relative = checked_relative(member.filename)
                if member.is_dir():
                    continue
                if stat.S_ISLNK(member.external_attr >> 16):
                    raise ValueError("Wheel symlinks are not supported in this probe")
                if relative.suffix.lower() in (".so", ".dylib", ".pyd", ".pth"):
                    raise ValueError("Unexpected native module or executable path hook")
                if any(part.endswith(".data") for part in relative.parts):
                    raise ValueError("Unreviewed wheel install scheme")
                total += member.file_size
                if total > 20 * 1024 * 1024:
                    raise ValueError("Expanded wheels exceed probe budget")
                output = destination.joinpath(*relative.parts)
                if output.exists():
                    raise ValueError("Overlapping wheel member")
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_bytes(archive.read(member))
        files.append({key: package[key] for key in ("name", "version", "file", "sha256", "bytes")})
    return files


def stage(app, target, arch, cache):
    archive = download_verified(URL, cache / ARCHIVE, SHA256)
    slice_name = "ios-arm64" if target == "device" else "ios-arm64_x86_64-simulator"
    framework_prefix = "Python.xcframework/" + slice_name + "/Python.framework/"
    common_prefix = "Python.xcframework/lib/"
    arch_prefix = "Python.xcframework/" + slice_name + "/lib-" + arch + "/"
    extension_records = []
    input_bytes = 0
    with tarfile.open(archive, "r:gz") as source:
        for member in source:
            checked_relative(member.name)
            if not member.isfile():
                # The archive's three symlinks are libpython aliases and the
                # upstream testbed link. None is needed in our deployed app.
                continue
            if member.name.startswith(framework_prefix):
                relative = member.name[len(framework_prefix):]
                output = app / "Frameworks/Python.framework" / relative
            elif member.name.startswith(common_prefix):
                relative = member.name[len(common_prefix):]
                output = app / "python/lib" / relative
            elif member.name.startswith(arch_prefix):
                relative = member.name[len(arch_prefix):]
                output = app / "python/lib" / relative
            else:
                continue
            if output.exists():
                raise ValueError("Unexpected common/slice file collision")
            input_bytes += member.size
            if input_bytes > 150 * 1024 * 1024:
                raise ValueError("Expanded runtime exceeds probe budget")
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_bytes(source.extractfile(member).read())
            if member.mode & 0o111:
                output.chmod(output.stat().st_mode | 0o111)

    dynload = app / "python/lib/python3.14/lib-dynload"
    if not dynload.is_dir():
        raise ValueError("Pinned runtime slice is incomplete")
    # Equivalent to the verified upstream build/utils.sh .fwork/.origin scheme,
    # implemented directly to record every moved binary and avoid shell globbing.
    for binary in sorted(dynload.rglob("*.so")):
        relative = binary.relative_to(dynload)
        module = ".".join((*relative.parts[:-1], relative.name.split(".", 1)[0]))
        if not re.fullmatch(r"[A-Za-z0-9_.]+", module):
            raise ValueError("Unexpected extension module name")
        framework = app / "Frameworks" / (module + ".framework")
        framework.mkdir()
        final_binary = framework / module
        before = {"source": binary.relative_to(app).as_posix(), "sha256": digest(binary), "bytes": binary.stat().st_size}
        binary.replace(final_binary)
        marker = binary.with_suffix(".fwork")
        marker.write_text(final_binary.relative_to(app).as_posix() + "\n", encoding="utf-8")
        (framework / (module + ".origin")).write_text(marker.relative_to(app).as_posix() + "\n", encoding="utf-8")
        info = {"CFBundleIdentifier": IDENTIFIER + "." + module.replace("_", "-"),
                "CFBundleExecutable": module, "CFBundleName": module,
                "CFBundlePackageType": "FMWK", "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1",
                "MinimumOSVersion": "14.0", "CFBundleSupportedPlatforms": ["iPhoneOS" if target == "device" else "iPhoneSimulator"]}
        (framework / "Info.plist").write_bytes(plistlib.dumps(info))
        privacy = binary.parent / (module.split(".")[-1] + ".xcprivacy")
        if privacy.exists():
            privacy.replace(framework / "PrivacyInfo.xcprivacy")
        extension_records.append(dict(before, framework=final_binary.relative_to(app).as_posix(), marker=marker.relative_to(app).as_posix()))
    if len(extension_records) < 40:
        raise ValueError("Insufficient standard-library native modules")
    package_dir = app / "app_packages"
    package_dir.mkdir()
    dependencies = stage_wheels(package_dir, cache)
    (app / "app").mkdir()
    shutil.copyfile(HERE / "probe_fixture.py", app / "app/probe_fixture.py")
    info = {"CFBundleIdentifier": IDENTIFIER, "CFBundleExecutable": "CPythonProbe",
            "CFBundleName": "CPythonProbe", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
            "MinimumOSVersion": "14.0", "UIDeviceFamily": [1, 2], "UILaunchScreen": {},
            "CFBundleSupportedPlatforms": ["iPhoneOS" if target == "device" else "iPhoneSimulator"],
            "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
            "NSLocalNetworkUsageDescription": "Owned local Python runtime fixture only."}
    (app / "Info.plist").write_bytes(plistlib.dumps(info))
    return {"support_archive": {"url": URL, "sha256": SHA256, "bytes": archive.stat().st_size},
            "target": target, "architecture": arch, "minimum_target": "14.0",
            "runtime_copied_bytes_before_framework_thinning": input_bytes,
            "extensions": extension_records, "dependencies": dependencies,
            "probe_inputs": {name: digest(HERE / name) for name in ("run_cpython_probe.py", "CPythonProbe.mm", "probe_fixture.py", "pure-dependencies.lock.json")}}


def run(*args, capture=False, timeout=180, progress=None):
    if progress is not None:
        progress["last_command"] = [str(value) for value in args]
    print("Running:", " ".join(map(str, args)), flush=True)
    result = subprocess.run(list(map(str, args)), check=True, text=True, timeout=timeout,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else ""


def compile_and_sign(app, out, target, arch, identity, progress):
    sdk_name = "iphoneos" if target == "device" else "iphonesimulator"
    sdk = run("xcrun", "--sdk", sdk_name, "--show-sdk-path", capture=True, progress=progress)
    suffix = "" if target == "device" else "-simulator"
    run("xcrun", "--sdk", sdk_name, "clang++", "-fobjc-arc", "-std=c++17", "-O1", "-g",
        "-target", arch + "-apple-ios14.0" + suffix, "-isysroot", sdk,
        "-F" + str(app / "Frameworks"), "-framework", "Python", "-framework", "Foundation",
        "-framework", "UIKit", "-Wl,-rpath,@executable_path/Frameworks",
        HERE / "CPythonProbe.mm", "-o", app / "CPythonProbe", progress=progress)
    return sign_app(app, out, arch, identity, progress)


def sign_app(app, out, arch, identity, progress):
    """Sign a prepared owned app; shared by native and Flutter experiments."""
    # Keep headers until the native executable has been compiled. Only remove
    # checked paths inside this newly-created disposable app, never user content.
    for name in ("Headers", "Modules"):
        path = app / "Frameworks/Python.framework" / name
        if path.exists():
            if not path.resolve().is_relative_to(app.resolve()):
                raise ValueError("Framework cleanup escaped probe app")
            shutil.rmtree(path)
    signed = []
    for framework in sorted((app / "Frameworks").glob("*.framework")):
        info = plistlib.loads((framework / "Info.plist").read_bytes())
        binary = framework / info["CFBundleExecutable"]
        archs = run("xcrun", "lipo", "-archs", binary, capture=True, progress=progress).split()
        if arch not in archs:
            raise ValueError("Framework missing requested architecture")
        if len(archs) > 1:
            thin = out / (framework.name + ".thin")
            run("xcrun", "lipo", binary, "-thin", arch, "-output", thin, progress=progress)
            thin.replace(binary)
        run("codesign", "--force", "--sign", identity, "--timestamp=none", framework, progress=progress)
        run("codesign", "--verify", "--strict", framework, progress=progress)
        signed.append({"framework": framework.name, "binary_sha256_after_sign": digest(binary)})
    run("codesign", "--force", "--sign", identity, "--timestamp=none", app, progress=progress)
    run("codesign", "--verify", "--strict", app, progress=progress)
    return signed


def simulator_run(app, udid, progress, identifier=IDENTIFIER, app_name="CPythonProbe"):
    diagnostic_identity(identifier, app_name)
    inventory = json.loads(run("xcrun", "simctl", "list", "devices", "available", "--json", capture=True, progress=progress))
    candidates = [(runtime, device) for runtime, devices in inventory["devices"].items()
                  if ".iOS-" in runtime for device in devices if device.get("isAvailable")
                  and device["name"].startswith("iPhone") and (not udid or device["udid"] == udid)]
    if not candidates:
        raise RuntimeError("No matching available iPhone simulator")
    def version(item):
        return tuple(map(int, re.findall(r"\d+", item[0].split(".iOS-", 1)[1])))
    candidates = [item for item in candidates if version(item) >= (14,)]
    if not candidates:
        raise RuntimeError("No matching iOS 14 or newer simulator")
    runtime, device = sorted(candidates, key=version)[0]
    udid = device["udid"]
    progress.update(simulator=device["name"], simulator_udid=udid, os_runtime=runtime,
                    minimum_ios14_runtime_tested=version((runtime, device))[0] == 14)
    if device["state"] != "Booted":
        run("xcrun", "simctl", "boot", udid, progress=progress)
    run("xcrun", "simctl", "bootstatus", udid, "-b", timeout=360, progress=progress)
    run("xcrun", "simctl", "install", udid, app, progress=progress)
    container = Path(run("xcrun", "simctl", "get_app_container", udid, identifier, "data", capture=True, progress=progress))
    result_file = container / "Documents/result.json"
    watchdog_file = container / "Documents/watchdog.json"
    result_file.unlink(missing_ok=True)
    watchdog_file.unlink(missing_ok=True)
    for name in ("progress.json", "exception.json", "native-stderr.log", "native-stdout.log", "python-progress.log"):
        (container / "Documents" / name).unlink(missing_ok=True)
    launched = False
    try:
        run("xcrun", "simctl", "launch", "--terminate-running-process", udid, identifier, timeout=90, progress=progress)
        launched = True
        deadline = time.monotonic() + 70
        while time.monotonic() < deadline:
            if result_file.exists():
                return json.loads(result_file.read_text(encoding="utf-8"))
            if watchdog_file.exists():
                shutil.copyfile(watchdog_file, app.parent / "app-watchdog.json")
                raise RuntimeError("Native watchdog recorded a timeout; no safe Python-thread kill was performed")
            time.sleep(0.25)
        raise RuntimeError("No app result. Inspect crash diagnostics; runtime is not accepted")
    finally:
        diagnostics = app.parent / "diagnostics"
        diagnostics.mkdir(exist_ok=True)
        for name in ("progress.json", "exception.json", "native-stderr.log", "native-stdout.log", "python-progress.log"):
            source = container / "Documents" / name
            if source.is_file() and not source.is_symlink():
                with source.open("rb") as stream:
                    content = stream.read(5 * 1024 * 1024)
                (diagnostics / name).write_bytes(content)
        if launched:
            # This is an external CI runner ending its own disposable app, not a
            # capability available to the production app to kill one source.
            subprocess.run(["xcrun", "simctl", "terminate", udid, identifier], check=False, timeout=30)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("simulator", "device"), default="simulator")
    parser.add_argument("--arch", choices=("arm64", "x86_64"))
    parser.add_argument("--stage-only", action="store_true", help="Prepare files only; does not compile, sign, install or run")
    parser.add_argument("--build-only", action="store_true", help="Compile/sign only; no install or runtime acceptance")
    parser.add_argument("--identity", default="-", help="Default ad-hoc identity is simulator-only, not device-install authorization")
    parser.add_argument("--udid", help="Optional specific available iPhone simulator")
    parser.add_argument("--cache-dir", type=Path, default=HERE / "downloads", help="Verified official archive and wheel cache")
    parser.add_argument("--output-dir", type=Path, default=HERE / "probe-output", help="Parent directory for a new disposable app and evidence")
    args = parser.parse_args()
    arch = args.arch or ("arm64" if args.platform == "device" or platform.machine() in ("arm64", "aarch64") else "x86_64")
    if args.platform == "device" and arch != "arm64":
        parser.error("The official device framework supports arm64 only")
    if args.platform == "device" and not (args.build_only or args.stage_only):
        parser.error("This runner cannot install on physical devices; request --build-only")
    if not args.stage_only and sys.platform != "darwin":
        parser.error("Native compilation and simulator execution require macOS with full Xcode")
    out_root = args.output_dir.resolve()
    out_root.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix=args.platform + "-" + arch + "-", dir=out_root))
    app = out / "CPythonProbe.app"
    app.mkdir()
    progress = {"passed": False, "phase": "stage", "output": str(out),
                "physical_device_tested": False, "flutter_integration_tested": False,
                "runtime_tested": False, "github_sha": os.environ.get("GITHUB_SHA", ""),
                "github_run_id": os.environ.get("GITHUB_RUN_ID", ""),
                "github_repository": os.environ.get("GITHUB_REPOSITORY", ""),
                "runner_os": os.environ.get("RUNNER_OS", platform.system()),
                "runner_arch": os.environ.get("RUNNER_ARCH", platform.machine()),
                "host_arch": platform.machine(), "target_arch": arch, "host_platform": platform.platform()}
    start_time = time.time()
    try:
        inputs = stage(app, args.platform, arch, args.cache_dir.resolve())
        write_json(out / "inputs.json", inputs)
        if args.stage_only:
            progress.update(phase="staged_only", staging_passed=True, runtime_tested=False)
        else:
            progress["phase"] = "compile_sign"
            inputs["signed_frameworks"] = compile_and_sign(app, out, args.platform, arch, args.identity, progress)
            write_json(out / "inputs.json", inputs)
            if args.build_only:
                progress.update(phase="compiled_signed_only", build_passed=True, runtime_tested=False)
            else:
                progress["phase"] = "simulator_runtime"
                report = simulator_run(app, args.udid, progress)
                write_json(out / "app-result.json", report)
                progress["runtime_tested"] = True
                validate_app_report(report, arch)
                progress.update(phase="simulator_completed", runtime_tested=True,
                                passed=bool(report.get("passed")), checks=len(report.get("checks", [])),
                                failure=report.get("failure", ""))
                if not progress["passed"] or progress["checks"] < 40:
                    progress["passed"] = False
                    raise RuntimeError("Native CPython fixture did not pass all required checks")
        write_json(out / "result.json", progress)
        print(json.dumps(progress, ensure_ascii=False, indent=2))
    except BaseException as error:
        progress.update(passed=False, failure=type(error).__name__ + ": " + str(error))
        write_json(out / "result.json", progress)
        print(json.dumps(progress, ensure_ascii=False, indent=2))
        raise
    finally:
        try:
            collect_diagnostics(out, progress, start_time)
        except OSError as error:
            progress["diagnostics_note"] = type(error).__name__
        write_json(out / "result.json", progress)


if __name__ == "__main__":
    main()
