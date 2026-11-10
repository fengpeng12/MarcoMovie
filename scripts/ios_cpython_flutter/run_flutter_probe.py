"""Build a disposable Flutter+CPython+Node+QuickJS iOS simulator experiment.

Reuses ios_cpython's pinned staging, signing and app-scoped diagnostic helpers.
No product source routing, existing app package or distribution is modified.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
TRANSPORT = HERE.parent / "ios_cpython_transport"
NATIVE_SOURCE = ROOT / "android/src/main/assets/python-native"
PRODUCT_TRANSPORT = ROOT / "flutter/src/core/python_http_transport.dart"
sys.path.insert(0, str(HERE.parent / "ios_cpython"))
import run_cpython_probe as native

IDENTIFIER = "com.pilipala.experimental.cpythonflutter"
APP_NAME = "CPythonFlutterProbe"
TRANSPORT_REQUIRED = frozenset((
    "transport_real_response", "transport_binary_bytes", "transport_json_body",
    "transport_form_body", "transport_cookie_duplicates", "transport_cookie_path_secure",
    "transport_cross_origin_strips_inherited", "transport_cross_origin_new_cookie",
    "transport_deadline", "transport_cancelled_wait", "transport_after_cancel_recovery",
    "transport_closed_adapter",
))
REQUIRED = frozenset((
    "actual_ios_flutter", "pinned_cpython", "owned_fixture_gate", "pinned_node18", "quickjs_execution",
    "opaque_unique_sessions", "unknown_source_rejected", "external_origin_rejected", "session_capacity_bounded",
    "home_classes", "source_instance_initial_count", "native_requests_version", "source_instance_state_separate",
    "subinterpreter_module_state_separate", "recommendations", "category_page", "search_unicode",
    "detail_opaque_id", "detail_bs4", "detail_episodes", "play_resolution", "synthetic_hls_prefix",
    "binary_proxy_status_headers", "binary_proxy_exact_bytes", "same_source_retained_for_proxy",
    "unknown_method_rejected", "python_exception_is_reported", "source_recovers_after_error",
    "release_existing", "released_handle_invalid", "release_idempotent", "other_session_survives_release",
    "new_session_identity", "new_session_state_reset", "quickjs_state_survives_python", "node_survives_python",
    "flutter_main_loop_responsive",
    "python_preserves_existing_sigint", "signal_policy_after_both",
    "launch_order_observed", "fixture_redirect_rejected", "source_recovers_after_redirect",
    "transport_real_response", "transport_binary_bytes", "transport_json_body",
    "transport_form_body", "transport_cookie_duplicates", "transport_cookie_path_secure",
    "transport_cross_origin_strips_inherited", "transport_cross_origin_new_cookie",
    "transport_deadline", "transport_cancelled_wait", "transport_after_cancel_recovery",
    "transport_closed_adapter", "transport_ui_responsive", "transport_native_cancel_ack",
    "transport_tasks_drained", "transport_no_server_errors", "transport_quickjs_survives",
    "transport_node_survives",
    "source_shared_host_home", "source_raw_extension", "source_relative_module",
    "source_package_resource", "source_http_transport", "source_init_once",
    "source_same_instance", "source_same_name_isolation", "source_recommendations",
    "source_category_filters", "source_search_unicode", "source_detail_opaque",
    "source_play_proxy_url", "source_proxy_get_bytes", "source_proxy_headers",
    "source_proxy_head", "source_proxy_retains_instance", "source_release",
    "source_released_proxy_not_rebound", "source_stale_handle",
    "source_other_session_survives", "source_recreate_state",
    "source_transport_drained", "source_server_clean", "source_ui_responsive",
    "source_quickjs_survives", "source_node_survives", "source_live_json", "source_live_text",
))


def validate_report(report, arch, order):
    if not isinstance(report, dict) or report.get("passed") is not True:
        raise ValueError("Flutter experiment did not pass")
    checks = report.get("checks")
    if not isinstance(checks, list) or len(checks) != len(REQUIRED):
        raise ValueError("Missing Flutter behavior checks")
    names = set()
    for entry in checks:
        if not isinstance(entry, dict) or entry.get("passed") is not True or not isinstance(entry.get("name"), str) or entry["name"] in names:
            raise ValueError("Failed, malformed or duplicated Flutter check")
        names.add(entry["name"])
    if not REQUIRED.issubset(names):
        raise ValueError("Required Flutter behavior missing")
    transport = report.get("transport", {})
    if (not isinstance(transport, dict) or type(transport.get("version")) is not int
            or transport.get("version") != 1 or transport.get("passed") is not True):
        raise ValueError("Native Python transport report missing")
    transport_checks = transport.get("checks")
    if not isinstance(transport_checks, list) or len(transport_checks) != len(TRANSPORT_REQUIRED):
        raise ValueError("Native Python transport inventory mismatch")
    transport_names = set()
    for entry in transport_checks:
        if (not isinstance(entry, dict) or entry.get("passed") is not True
                or entry.get("name") not in TRANSPORT_REQUIRED
                or entry["name"] in transport_names):
            raise ValueError("Native Python transport check invalid")
        transport_names.add(entry["name"])
    capabilities = report.get("capabilities", {})
    if capabilities.get("arch") != arch or not str(capabilities.get("runtime", "")).startswith("3.14.10 "):
        raise ValueError("Actual CPython architecture/version mismatch")
    if capabilities.get("ownedFixtureOnly") is not True or capabilities.get("hardCancel") is not False:
        raise ValueError("Fixture gate/cancellation capability mismatch")
    if capabilities.get("initialized") is not True or capabilities.get("pythonPreservedSigint") is not True:
        raise ValueError("Python initialization/signal evidence missing")
    before = capabilities.get("signalsBeforePython", {})
    after = capabilities.get("signalsAfterPython", {})
    all_signals = report.get("after_all_signals", {})
    if (before.get("sigint") not in ("default", "ignored", "custom")
            or after.get("sigint") != before.get("sigint")
            or after.get("sigpipe") != "ignored" or all_signals.get("sigpipe") != "ignored"):
        raise ValueError("Actual signal disposition evidence missing")
    if report.get("node_runtime") != "v18.20.4":
        raise ValueError("Actual Node runtime mismatch")
    if order not in ("python-first", "node-first") or report.get("order") != order:
        raise ValueError("Independent launch order was not verified")
    for field in ("physical_device_tested", "user_sources_tested", "hard_cancellation_tested"):
        if report.get(field) is not False:
            raise ValueError("Experiment overstates evidence boundary")


def copy_package(source, destination):
    shutil.copytree(source, destination, ignore=shutil.ignore_patterns(
        "build", ".dart_tool", ".git", ".symlinks", "Frameworks", "Pods", "example", "test"))


def stage_layout(out, arch, cache, node_cache):
    staged = out / "python-staged.app"
    staged.mkdir()
    inputs = native.stage(staged, "simulator", arch, cache)
    shutil.copyfile(HERE / "session_fixture.py", staged / "app/session_fixture.py")
    shutil.copyfile(HERE / "source_session_fixture.py", staged / "app/source_session_fixture.py")
    shutil.copyfile(NATIVE_SOURCE / "host.py", staged / "app/native_source_host.py")
    shutil.copytree(NATIVE_SOURCE / "base", staged / "app/base", ignore=shutil.ignore_patterns("__pycache__"))
    for name in ("requests_adapter.py", "transport_fixture.py"):
        shutil.copyfile(TRANSPORT / name, staged / "app" / name)
    packages = out / "packages"
    plugin = packages / "cpython_fixture"
    classes = plugin / "ios/Classes"
    classes.mkdir(parents=True)
    for name in ("CPythonFixturePlugin.h", "CPythonFixturePlugin.mm"):
        shutil.copyfile(HERE / name, classes / name)
    for name in ("FlutterPythonTransport.h", "FlutterPythonTransport.mm"):
        shutil.copyfile(TRANSPORT / name, classes / name)
    shutil.copyfile(ROOT / "LICENSE", plugin / "LICENSE")
    shutil.copytree(staged / "Frameworks/Python.framework", plugin / "ios/Frameworks/Python.framework")
    (plugin / "pubspec.yaml").write_text("""name: cpython_fixture
version: 0.0.1
publish_to: none
environment:
  sdk: '>=3.8.0 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
flutter:
  plugin:
    platforms:
      ios:
        pluginClass: CPythonFixturePlugin
""", encoding="utf-8")
    (plugin / "ios/cpython_fixture.podspec").write_text("""Pod::Spec.new do |s|
  s.name = 'cpython_fixture'
  s.version = '0.0.1'
  s.summary = 'Disposable owned-fixture CPython experiment.'
  s.homepage = 'https://github.com/Pilipala9919/MarcoMovie'
  s.license = { :type => 'GPL-3.0-only', :file => '../LICENSE' }
  s.author = { 'Pilipala' => '' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '14.0'
  s.vendored_frameworks = 'Frameworks/Python.framework'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'OTHER_LDFLAGS' => '$(inherited) -framework Python' }
end
""", encoding="utf-8")
    for name in ("catpaw_runtime", "quickjs_engine"):
        copy_package(ROOT / "flutter/packages" / name, packages / name)
    # Preserve the product bridge's license in its relocated temporary package.
    shutil.copyfile(ROOT / "LICENSE", packages / "catpaw_runtime/LICENSE")
    node_spec = packages / "catpaw_runtime/ios/catpaw_runtime.podspec"
    node_spec.write_text(node_spec.read_text().replace("'../../../../LICENSE'", "'../LICENSE'"), encoding="utf-8")
    spec = importlib.util.spec_from_file_location("owned_node_preparation", HERE.parent / "prepare_catpaw_runtime.py")
    node = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(node)
    previous = os.environ.get("MARCOMOVIE_RUNTIME_CACHE")
    os.environ["MARCOMOVIE_RUNTIME_CACHE"] = str(node_cache)
    try:
        node.prepare("ios", packages / "catpaw_runtime/ios/Frameworks")
    finally:
        if previous is None:
            os.environ.pop("MARCOMOVIE_RUNTIME_CACHE", None)
        else:
            os.environ["MARCOMOVIE_RUNTIME_CACHE"] = previous
    inputs["node_archive"] = {"url": node.ASSETS["ios"][0], "sha256": node.ASSETS["ios"][1]}
    inputs["flutter_probe_inputs"] = {p.name: native.digest(p) for p in sorted(HERE.iterdir()) if p.is_file()}
    inputs["transport_inputs"] = {p.relative_to(ROOT).as_posix(): native.digest(p)
        for p in sorted(TRANSPORT.rglob("*")) if p.is_file()
        and not any(part in ("__pycache__", ".dart_tool", "build") for part in p.parts)}
    inputs["native_source_inputs"] = {p.relative_to(ROOT).as_posix(): native.digest(p)
        for p in sorted(NATIVE_SOURCE.rglob("*.py"))}
    inputs["product_transport_inputs"] = {PRODUCT_TRANSPORT.relative_to(ROOT).as_posix(): native.digest(PRODUCT_TRANSPORT)}
    inputs["existing_runtime_inputs"] = {p.relative_to(ROOT).as_posix(): native.digest(p)
        for parent in (ROOT / "flutter/packages/catpaw_runtime/ios/Classes", ROOT / "flutter/packages/quickjs_engine")
        for p in sorted(parent.rglob("*")) if p.is_file()
        and not any(part in ("build", ".dart_tool", ".git", "Frameworks", "Pods") for part in p.parts)}
    return staged, inputs


def project_run(project, out, progress, *args, timeout=600):
    progress["last_command"] = list(map(str, args))
    log = out / "build.log"
    with log.open("a", encoding="utf-8") as output:
        output.write("Running: " + " ".join(map(str, args)) + "\n");output.flush()
        result = subprocess.run(list(map(str, args)), cwd=project, stdout=output,
                                stderr=subprocess.STDOUT, text=True, timeout=timeout)
    if result.returncode:
        print("\n".join(log.read_text(encoding="utf-8", errors="replace").splitlines()[-120:]))
        raise RuntimeError("Flutter experiment command failed; see build.log")


def prepare_project(out, flutter, progress):
    project = out / "flutter-app"
    project_run(out, out, progress, flutter, "create", "--platforms=ios", "--no-pub", "--project-name=cpython_flutter_probe", project)
    (project / "pubspec.yaml").write_text("""name: cpython_flutter_probe
version: 0.0.1+1
publish_to: none
environment:
  sdk: '>=3.8.0 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
  cpython_fixture:
    path: ../packages/cpython_fixture
  catpaw_runtime:
    path: ../packages/catpaw_runtime
  quickjs_engine:
    path: ../packages/quickjs_engine
flutter:
  config:
    enable-swift-package-manager: false
  uses-material-design: true
  assets:
    - assets/node-fixture.cjs
""", encoding="utf-8")
    shutil.copyfile(HERE / "main.dart", project / "lib/main.dart")
    shutil.copyfile(HERE / "transport_fixture.dart", project / "lib/transport_fixture.dart")
    shutil.copyfile(HERE / "source_fixture.dart", project / "lib/source_fixture.dart")
    shutil.copyfile(PRODUCT_TRANSPORT, project / "lib/python_http_transport.dart")
    shutil.copyfile(TRANSPORT / "dart/fixture_http_transport.dart", project / "lib/fixture_http_transport.dart")
    (project / "assets").mkdir(exist_ok=True)
    shutil.copyfile(HERE / "node-fixture.cjs", project / "assets/node-fixture.cjs")
    # This touches only the generated disposable project. Product preparation is
    # intentionally not imported: it has unrelated icon/layout/source side effects.
    pbx = project / "ios/Runner.xcodeproj/project.pbxproj"
    pbx.write_text(re.sub(r"IPHONEOS_DEPLOYMENT_TARGET\s*=\s*[0-9.]+;", "IPHONEOS_DEPLOYMENT_TARGET = 14.0;", pbx.read_text()), encoding="utf-8")
    project_run(project, out, progress, flutter, "pub", "get")
    podfile = project / "ios/Podfile"
    if podfile.exists():
        text = re.sub(r"#?\s*platform\s+:ios\s*,\s*'[^']+'", "platform :ios, '14.0'", podfile.read_text())
        podfile.write_text(text, encoding="utf-8")
    return project


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--cache-dir", type=Path, required=True)
    parser.add_argument("--node-cache-dir", type=Path)
    parser.add_argument("--arch", choices=("arm64", "x86_64"))
    parser.add_argument("--flutter", default="flutter")
    parser.add_argument("--udid")
    parser.add_argument("--stage-only", action="store_true")
    args = parser.parse_args()
    arch = args.arch or ("arm64" if platform.machine() == "arm64" else "x86_64")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix="flutter-" + arch + "-", dir=args.output_dir.resolve()))
    progress = {"passed": False, "runtime_tested": False, "physical_device_tested": False,
        "user_sources_tested": False, "target_arch": arch, "host_arch": platform.machine(),
        "runner_arch": os.environ.get("RUNNER_ARCH"), "github_sha": os.environ.get("GITHUB_SHA"),
        "github_run_id": os.environ.get("GITHUB_RUN_ID"), "phase": "staging"}
    started = time.time()
    try:
        staged, inputs = stage_layout(out, arch, args.cache_dir.resolve(), (args.node_cache_dir or args.cache_dir / "node").resolve())
        native.write_json(out / "inputs.json", inputs)
        if args.stage_only:
            progress["phase"] = "staged_only"
            return
        if sys.platform != "darwin":
            raise RuntimeError("Flutter iOS compile/run requires macOS; staging is not runtime acceptance")
        version = json.loads(native.run(args.flutter, "--version", "--machine", capture=True, progress=progress))
        if version.get("frameworkVersion") != "3.38.9":
            raise ValueError("Experiment requires the reviewed Flutter 3.38.9 toolchain")
        inputs["flutter_toolchain"] = version
        project = prepare_project(out, args.flutter, progress)
        progress["phase"] = "building"
        project_run(project, out, progress, args.flutter, "build", "ios", "--simulator", "--debug", "--no-codesign", timeout=900)
        built = project / "build/ios/iphonesimulator/Runner.app"
        app = out / (APP_NAME + ".app")
        shutil.copytree(built, app, symlinks=True)
        info = plistlib.loads((app / "Info.plist").read_bytes())
        old_executable = info["CFBundleExecutable"]
        if old_executable != "Runner":
            raise ValueError("Unexpected generated Flutter executable")
        (app / old_executable).rename(app / APP_NAME)
        info.update(CFBundleExecutable=APP_NAME, CFBundleIdentifier=IDENTIFIER, CFBundleName=APP_NAME,
                    NSAppTransportSecurity={"NSAllowsLocalNetworking": True},
                    NSLocalNetworkUsageDescription="Owned local runtime integration fixture only.")
        (app / "Info.plist").write_bytes(plistlib.dumps(info))
        for name in ("python", "app", "app_packages", "Frameworks"):
            shutil.copytree(staged / name, app / name, dirs_exist_ok=True)
        native.write_json(app / "fixture-order.json", "python-first")
        inputs["signed_frameworks"] = native.sign_app(app, out, arch, "-", progress)
        native.write_json(out / "inputs.json", inputs)
        progress["phase"] = "simulator_running"
        reports = {}
        for order in ("python-first", "node-first"):
            order_out = out / order
            order_out.mkdir()
            progress["launch_order"] = order
            native.write_json(app / "fixture-order.json", order)
            native.run("codesign", "--force", "--sign", "-", "--timestamp=none", app, progress=progress)
            native.run("codesign", "--verify", "--strict", app, progress=progress)
            try:
                report = native.simulator_run(app, progress.get("simulator_udid", args.udid), progress, IDENTIFIER, APP_NAME)
                native.write_json(order_out / "app-result.json", report)
                validate_report(report, arch, order)
                reports[order] = report
            finally:
                if (out / "diagnostics").exists():
                    shutil.copytree(out / "diagnostics", order_out / "diagnostics", dirs_exist_ok=True)
                native.collect_diagnostics(order_out, progress, started, IDENTIFIER, APP_NAME)
        native.write_json(out / "app-result.json", {"passed": True, "orders": reports})
        progress.update(passed=True, runtime_tested=True, phase="simulator_completed", checks=sum(len(r["checks"]) for r in reports.values()))
    except Exception as error:
        progress["failure"] = type(error).__name__ + ": " + str(error)
        raise
    finally:
        native.collect_diagnostics(out, progress, started, IDENTIFIER, APP_NAME)
        native.write_json(out / "result.json", progress)
        print(json.dumps({"output": str(out), **progress}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
