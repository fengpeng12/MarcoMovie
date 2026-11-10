"""Host-side packaging and OWNED fixture checks; never claims iOS execution."""
import argparse
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import platform
import sys
import tempfile

import run_cpython_probe as probe


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-dir", type=Path, default=probe.HERE / "downloads")
    parser.add_argument("--output-dir", type=Path, default=probe.HERE / "host-check-output")
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix="check-", dir=args.output_dir.resolve()))
    checks = []

    def check(name, result):
        checks.append({"name": name, "passed": bool(result)})
        if not result:
            raise AssertionError(name)

    probe.diagnostic_identity(probe.IDENTIFIER, "CPythonProbe")
    probe.diagnostic_identity("com.pilipala.experimental.cpythonflutter", "CPythonFlutterProbe")
    for identifier, app_name in (("com.other.app", "OtherApp"), (probe.IDENTIFIER, "*"),
                                 (probe.IDENTIFIER, "Runner"), (probe.IDENTIFIER, "CPythonFlutterProbe")):
        try:
            probe.diagnostic_identity(identifier, app_name)
        except ValueError:
            check("reject_unowned_diagnostic_identity_" + app_name, True)
        else:
            check("reject_unowned_diagnostic_identity_" + app_name, False)

    for path in ("../escape", "/absolute", "C:/absolute", "a/../escape", "a\\b", "", "dir/name:stream"):
        try:
            probe.checked_relative(path)
        except ValueError:
            check("reject_unsafe_path_" + repr(path), True)
        else:
            check("reject_unsafe_path_" + repr(path), False)
    bad = out / "tampered-cache"
    bad.write_bytes(b"modified cached data")
    try:
        probe.download_verified("https://unused.invalid/never-requested", bad, "0" * 64)
    except ValueError:
        check("reject_cached_hash_mismatch_without_network", True)
    else:
        check("reject_cached_hash_mismatch_without_network", False)

    lock = json.loads((probe.HERE / "pure-dependencies.lock.json").read_text(encoding="utf-8"))
    accepted = {"passed": True, "native_arch": "arm64", "runtime": "3.14.10 (synthetic validation fixture)",
                "checks": [{"name": name, "passed": True} for name in sorted(probe.REQUIRED_CHECKS)],
                "fixture": {"passed": True, "platform": "ios", "runtime": "3.14.10 (synthetic validation fixture)",
                            "dependencies": {item["name"]: item["version"] for item in lock["packages"]}}}
    probe.validate_app_report(accepted, "arm64")
    check("accept_well_formed_synthetic_report_contract_not_runtime_evidence", True)
    mutations = {
        "aggregate_false": lambda value: value.update(passed=False),
        "wrong_runtime": lambda value: value.update(runtime="3.13.13 (wrong)"),
        "wrong_arch": lambda value: value.update(native_arch="x86_64"),
        "duplicate_check": lambda value: value["checks"].append(value["checks"][0]),
        "false_check": lambda value: value["checks"][0].update(passed=False),
        "string_true": lambda value: value["checks"][0].update(passed="true"),
        "missing_check": lambda value: value["checks"].pop(),
        "few_checks": lambda value: value.update(checks=value["checks"][:10]),
        "host_fixture": lambda value: value["fixture"].update(platform="win32"),
        "dependency_mismatch": lambda value: value["fixture"]["dependencies"].update(requests="0"),
    }
    for name, mutate in mutations.items():
        invalid = copy.deepcopy(accepted)
        mutate(invalid)
        try:
            probe.validate_app_report(invalid, "arm64")
        except ValueError:
            check("reject_report_" + name, True)
        else:
            check("reject_report_" + name, False)

    staging = []
    for target, arch in (("simulator", "x86_64"), ("simulator", "arm64"), ("device", "arm64")):
        app = out / (target + "-" + arch) / "CPythonProbe.app"
        app.mkdir(parents=True)
        inputs = probe.stage(app, target, arch, args.cache_dir.resolve())
        check(target + "_" + arch + "_67_extensions", len(inputs["extensions"]) == 67)
        check(target + "_" + arch + "_no_unprocessed_so", not list(app.rglob("*.so")))
        for entry in inputs["extensions"]:
            binary = app / entry["framework"]
            marker = app / entry["marker"]
            check(target + "_" + arch + "_framework_" + binary.name,
                  hashlib.sha256(binary.read_bytes()).hexdigest() == entry["sha256"]
                  and marker.read_text().strip() == entry["framework"]
                  and binary.with_name(binary.name + ".origin").read_text().strip() == entry["marker"])
        staging.append({"target": target, "arch": arch, "extensions": len(inputs["extensions"]),
                        "input_bytes": inputs["runtime_copied_bytes_before_framework_thinning"], "app": str(app)})
        if target == "simulator" and arch == "x86_64":
            pure_packages = app / "app_packages"

    # This imports only locked pure wheels and our own fixture. The iOS standard
    # library/framework paths are never added to the host interpreter's sys.path.
    sys.path.insert(0, str(pure_packages))
    import probe_fixture
    fixture = json.loads(probe_fixture.run_probe(str(out / "fixture-state")))
    check("owned_host_fixture", fixture["passed"] and len(fixture["checks"]) == 30)
    report = {"passed": all(entry["passed"] for entry in checks), "checks": checks,
              "host": {"os": platform.platform(), "python": sys.version}, "staging": staging,
              "fixture": fixture, "ios_compiled": False, "ios_executed": False,
              "scope": "Host-side archive integrity/layout and synthetic pure-Python behavior only"}
    probe.write_json(out / "local-result.json", report)
    print(json.dumps({"passed": report["passed"], "packaging_checks": len(checks),
                      "host_fixture_checks": len(fixture["checks"]), "result": str(out / "local-result.json"),
                      "ios_executed": False}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
