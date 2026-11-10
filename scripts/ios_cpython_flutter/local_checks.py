"""Host-side owned-fixture and report validation; does not execute iOS/Flutter."""
import argparse
import base64
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time

import run_flutter_probe as probe


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--node", required=True)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix="host-", dir=args.output_dir.resolve()))
    checks = []

    def check(name, condition):
        checks.append({"name": name, "passed": bool(condition)})
        if not condition:
            raise AssertionError(name)

    accepted = {"passed": True, "checks": [{"name": name, "passed": True} for name in sorted(probe.REQUIRED)],
        "transport": {"version": 1, "passed": True,
                      "checks": [{"name": name, "passed": True} for name in sorted(probe.TRANSPORT_REQUIRED)]},
        "capabilities": {"arch": "arm64", "runtime": "3.14.10 (synthetic validator fixture)", "ownedFixtureOnly": True, "hardCancel": False,
                         "initialized": True, "pythonPreservedSigint": True,
                         "signalsBeforePython": {"sigpipe": "default", "sigint": "default"},
                         "signalsAfterPython": {"sigpipe": "ignored", "sigint": "default"}},
        "after_all_signals": {"sigpipe": "ignored", "sigint": "custom"},
        "order": "python-first", "node_runtime": "v18.20.4", "physical_device_tested": False, "user_sources_tested": False, "hard_cancellation_tested": False}
    probe.validate_report(accepted, "arm64", "python-first")
    check("synthetic_validation_contract_only", True)
    for name, mutate in {
        "false_pass": lambda v: v.update(passed=False), "wrong_runtime": lambda v: v["capabilities"].update(runtime="3.13"),
        "wrong_arch": lambda v: v["capabilities"].update(arch="x86_64"), "wrong_node": lambda v: v.update(node_runtime="v22.0.0"),
        "missing_check": lambda v: v["checks"].pop(), "false_check": lambda v: v["checks"][0].update(passed=False),
        "duplicate": lambda v: v["checks"].append(v["checks"][0]), "string_true": lambda v: v["checks"][0].update(passed="true"),
        "user_sources_claim": lambda v: v.update(user_sources_tested=True), "hard_cancel_claim": lambda v: v["capabilities"].update(hardCancel=True),
        "wrong_order": lambda v: v.update(order="node-first"),
        "missing_signal_snapshot": lambda v: v["capabilities"].pop("signalsBeforePython"),
        "sigpipe_reset_after_node": lambda v: v["after_all_signals"].update(sigpipe="default"),
        "extra_check": lambda v: v["checks"].append({"name": "unexpected", "passed": True}),
        "missing_transport": lambda v: v.pop("transport"),
        "transport_boolean_version": lambda v: v["transport"].update(version=True),
        "false_transport_check": lambda v: v["transport"]["checks"][0].update(passed=False),
        "duplicate_transport_check": lambda v: v["transport"]["checks"].__setitem__(1, v["transport"]["checks"][0]),
    }.items():
        invalid = copy.deepcopy(accepted);mutate(invalid)
        try:
            probe.validate_report(invalid, "arm64", "python-first")
        except ValueError:
            check("reject_" + name, True)
        else:
            check("reject_" + name, False)

    packages = out / "packages"
    packages.mkdir()
    probe.native.stage_wheels(packages, args.cache_dir.resolve())
    sys.path.insert(0, str(packages))
    import session_fixture
    ready = out / "ready.json"
    with (out / "node.log").open("wb") as log:
        child = subprocess.Popen([args.node, "--jitless", str(probe.HERE / "node-fixture.cjs"), str(out), str(ready)], stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 10
            while not ready.exists() and child.poll() is None and time.monotonic() < deadline:
                time.sleep(0.05)
            endpoint = json.loads(ready.read_text())
            check("actual_node18_fixture", endpoint["runtime"] == "v18.20.4")
            spider = session_fixture.create(endpoint["origin"])
            home = session_fixture.dispatch(spider, "home", [True])
            check("home", home["class"][0]["type_name"] == "电影" and home["fixture_calls"] == 1)
            check("recommendations", session_fixture.dispatch(spider, "homeVod", [])["list"][0]["vod_name"] == "本机示例")
            check("category", session_fixture.dispatch(spider, "category", ["film", "2", False, {}])["page"] == 2)
            check("search_unicode", session_fixture.dispatch(spider, "search", ["中文", False])["list"][0]["vod_name"] == "中文")
            detail = session_fixture.dispatch(spider, "detail", [["opaque/$#?中文"]])["list"][0]
            check("detail", detail["vod_id"] == "opaque/$#?中文" and detail["vod_content"] == "本机详情")
            play = session_fixture.dispatch(spider, "play", ["local", "episode-1", []])
            check("play", play["parse"] == 0 and play["episode"] == "episode-1")
            proxy = session_fixture.dispatch(spider, "proxy", [{}])
            check("binary_bytes", base64.b64decode(proxy["bodyBase64"]) == bytes([0, 255, 128, 13, 10, 65]))
            check("binary_headers_status", proxy["status"] == 206 and proxy["headers"]["X-Fixture"] == "bytes")
            check("same_instance_state", proxy["fixture_calls"] == 7)
            try:
                session_fixture.dispatch(spider, "detail", [[]])
            except IndexError:
                check("real_error_preserved", True)
            else:
                check("real_error_preserved", False)
            check("recover_after_error", session_fixture.dispatch(spider, "home", [False])["fixture_calls"] == 8)
            try:
                session_fixture.dispatch(spider, "search", ["redirect-fixture", False])
            except ValueError as error:
                check("redirect_rejected_before_following", "does not follow redirects" in str(error))
            else:
                check("redirect_rejected_before_following", False)
            check("recover_after_redirect", session_fixture.dispatch(spider, "home", [False])["fixture_calls"] == 10)
            check("manifest_prefix", spider.session.get(play["url"], timeout=2).content[:8] == b"#EXTM3U\n")
            session_fixture.close(spider)
        finally:
            child.terminate()
            child.wait(timeout=5)
    report = {"passed": all(item["passed"] for item in checks), "checks": checks,
              "ios_executed": False, "flutter_executed": False, "scope": "Host synthetic Node18/Python protocol + report contract only"}
    probe.native.write_json(out / "local-result.json", report)
    print(json.dumps({"passed": report["passed"], "checks": len(checks), "result": str(out / "local-result.json"), "ios_executed": False}, indent=2))


if __name__ == "__main__":
    main()
