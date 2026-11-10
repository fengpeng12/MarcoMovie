"""Real locked requests + owned loopback HTTP checks; no iOS/native execution."""
import argparse
import base64
import gzip
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.metadata
import importlib.util
import json
from pathlib import Path
import socket
import sys
import tempfile
import threading
import time
from urllib.parse import urlsplit, parse_qs

HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix="requests-bridge-", dir=args.output_dir.resolve()))
    checks = []
    completed = False

    def check(name, condition):
        if any(item["name"] == name for item in checks):
            raise AssertionError("Duplicate check name")
        checks.append({"name": name, "passed": bool(condition)})
        if not condition:
            raise AssertionError(name)

    native_path = HERE.parent / "ios_cpython" / "run_cpython_probe.py"
    spec = importlib.util.spec_from_file_location("owned_cpython_probe", native_path)
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    lock = json.loads((native_path.parent / "pure-dependencies.lock.json").read_text())
    # This checker never downloads. Require every already-reviewed wheel locally.
    for package in lock["packages"]:
        wheel = args.cache_dir / "wheels" / package["file"]
        if not wheel.is_file() or hashlib.sha256(wheel.read_bytes()).hexdigest() != package["sha256"]:
            raise ValueError("Missing or mismatched locked wheel: " + package["file"])
    packages = out / "packages"
    packages.mkdir()
    inputs = helper.stage_wheels(packages, args.cache_dir.resolve())
    sys.path.insert(0, str(packages))
    import requests
    import urllib3
    from requests_adapter import (BridgeSession, RequestsBridgeAdapter, CallContext, CallCancelled,
                                  BridgeProtocolError, UnsupportedFeature, BodyLimitError,
                                  BridgeTransportError, MAX_BODY)
    from urllib3.response import HTTPResponse
    check("locked_dependency_versions", all(importlib.metadata.version(p["name"]) == p["version"] for p in inputs))
    check("locked_requests_module_path", Path(requests.__file__).is_relative_to(packages))
    check("locked_urllib3_module_path", Path(urllib3.__file__).is_relative_to(packages))

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def do_GET(self):
            self.reply()

        do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = do_HEAD = do_GET

        def reply(self):
            path = urlsplit(self.path).path
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            self.server.seen.append((self.command, path, dict(self.headers)))
            status, headers = 200, []
            payload = json.dumps({"method": self.command, "path": self.path,
                                  "body": base64.b64encode(body).decode(),
                                  "headers": dict(self.headers)}).encode()
            kind = "application/json; charset=utf-8"
            if path == "/seed":
                headers = [("Set-Cookie", "root=one; Path=/"),
                           ("Set-Cookie", "only=path; Path=/scope"),
                           ("Set-Cookie", "secure=yes; Secure; Path=/"),
                           ("Set-Cookie", "wrong=reject; Domain=invalid.test; Path=/"),
                           ("Set-Cookie", "expired=no; Max-Age=0; Path=/")]
            elif path in ("/same", "/cross", "/cross-chain", "/cross-login", "/cross-expire", "/b-login", "/b-login-expire", "/b-delete", "/return-chain", "/return", "/loop", "/slow-redirect"):
                status = 302
                target = self.server.other + "/echo" if path == "/cross" else "/echo"
                if path == "/loop":
                    target = "/loop"
                if path == "/cross-chain":
                    target = self.server.other + "/same"
                if path == "/cross-login":
                    target = self.server.other + "/b-login"
                if path == "/cross-expire":
                    target = self.server.other + "/b-login-expire"
                if path == "/b-login-expire":
                    target = "/b-delete"
                if path == "/return-chain":
                    target = self.server.other + "/return"
                if path == "/return":
                    target = self.server.other + "/same"
                if path == "/slow-redirect":
                    time.sleep(0.06)
                    target = "/slow"
                headers = [("Location", target), ("Set-Cookie", "redirect=retained; Path=/")]
                if path in ("/b-login", "/b-login-expire"):
                    headers = [("Location", target), ("Set-Cookie", "own_b=fresh; Path=/"),
                               ("Set-Cookie", "b_secure=no; Secure; Path=/"),
                               ("Set-Cookie", "b_scope=no; Path=/different")]
                if path == "/b-delete":
                    headers = [("Location", target), ("Set-Cookie", "own_b=deleted; Max-Age=0; Path=/")]
                payload = b"redirect"
            elif path == "/307":
                status, headers, payload = 307, [("Location", "/echo")], b""
            elif path == "/binary":
                payload, kind = bytes((0, 255, 128, 65)), "application/octet-stream"
                if self.headers.get("Range") == "bytes=1-2":
                    status, payload, headers = 206, payload[1:3], [("Content-Range", "bytes 1-2/4")]
            elif path == "/error":
                status, payload = 503, b'{"error":"owned service unavailable"}'
            elif path == "/bad-json":
                payload = b"not json"
            elif path == "/slow":
                time.sleep(0.12)
                payload = b'{"late":true}'
                headers = [("Set-Cookie", "late=must-not-store; Path=/")]
            elif path == "/large":
                payload = b"x" * (MAX_BODY + 1)
            elif path in ("/gzip", "/gzip-bomb"):
                payload = gzip.compress(b"x" * (MAX_BODY + 1) if path == "/gzip-bomb" else b'{"compressed":true}')
                headers = [("Content-Encoding", "gzip")]
            self.send_response(status)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(payload)))
            for name, value in headers:
                self.send_header(name, value)
            self.end_headers()
            if self.command != "HEAD":
                try:
                    self.wfile.write(payload)
                except (ConnectionError, BrokenPipeError):
                    pass

    servers = [ThreadingHTTPServer(("127.0.0.1", 0), Handler) for _ in range(2)]
    for i, server in enumerate(servers):
        server.daemon_threads = True
        server.seen = []
        server.other = "http://127.0.0.1:" + str(servers[1 - i].server_port)
        threading.Thread(target=server.serve_forever, daemon=True).start()
    base = "http://127.0.0.1:" + str(servers[0].server_port)
    calls = []

    def http_bridge(envelope, context, *, ignore_cancel=False):
        calls.append(envelope)
        parsed = urlsplit(envelope["url"])
        if parsed.hostname != "127.0.0.1" or parsed.port not in {s.server_port for s in servers}:
            raise AssertionError("Test bridge only permits its two owned loopback servers")
        conn = http.client.HTTPConnection(parsed.hostname, parsed.port,
                                          timeout=envelope["connectTimeoutMs"] / 1000)
        try:
            conn.connect()
            conn.sock.settimeout(envelope["readTimeoutMs"] / 1000)
            conn.request(envelope["method"], parsed.path + ("?" + parsed.query if parsed.query else ""),
                         body=envelope["body"], headers=dict(envelope["headers"]))
            raw = conn.getresponse()
            body = raw.read(MAX_BODY + 1)
            if not ignore_cancel:
                context.check()
            return {"version": 1, "callId": envelope["callId"], "requestId": envelope["requestId"],
                    "url": envelope["url"], "status": raw.status, "reason": raw.reason,
                    "headers": [list(pair) for pair in raw.getheaders()], "body": body}
        except socket.timeout as error:
            raise BridgeTransportError("timeout") from error
        finally:
            conn.close()

    def rejects(name, exception, fn):
        try:
            fn()
        except exception:
            check(name, True)
        else:
            check(name, False)

    session = BridgeSession(http_bridge)
    try:
        with session.call(CallContext(10)):
            response = session.post(base + "/echo?q=original", params={"item": ["a", "b"], "title": "测试"}, json={"title": "原字节"})
            echo = response.json()
            check("real_response_and_urllib3_raw", isinstance(response, requests.Response) and isinstance(response.raw, HTTPResponse))
            check("json_body_not_double_encoded", json.loads(base64.b64decode(echo["body"])) == {"title": "原字节"})
            check("query_repeated_and_unicode", parse_qs(urlsplit(echo["path"]).query) == {"q": ["original"], "item": ["a", "b"], "title": ["测试"]})
            form = session.post(base + "/echo", data={"item": ["one", "two"], "title": "表单"}).json()
            check("form_prepared_bytes", parse_qs(base64.b64decode(form["body"]).decode()) == {"item": ["one", "two"], "title": ["表单"]})
            raw = bytes((0, 255, 128, 65))
            binary = session.post(base + "/echo", data=raw, headers={"Content-Type": "application/octet-stream"}).json()
            check("arbitrary_binary_upload", base64.b64decode(binary["body"]) == raw)
            check("binary_download", session.get(base + "/binary").content == raw)
            partial = session.get(base + "/binary", headers={"Range": "bytes=1-2"})
            check("range_and_content_range", partial.status_code == 206 and partial.content == raw[1:3] and partial.headers["Content-Range"] == "bytes 1-2/4")
            head = session.head(base + "/binary")
            check("head_keeps_metadata_no_body", head.content == b"" and head.headers["Content-Length"] == "4")
            check("options_method", session.options(base + "/echo").json()["method"] == "OPTIONS")
            error = session.get(base + "/error")
            check("http_error_keeps_body", error.status_code == 503 and error.json()["error"] == "owned service unavailable")
            rejects("raise_for_status_real_error", requests.HTTPError, error.raise_for_status)
            rejects("json_error_real_type", requests.exceptions.JSONDecodeError, lambda: session.get(base + "/bad-json").json())
            check("gzip_decoded_once", session.get(base + "/gzip").json() == {"compressed": True})
            rejects("wire_body_limit", BodyLimitError, lambda: session.get(base + "/large"))
            rejects("decoded_body_limit", BodyLimitError, lambda: session.get(base + "/gzip-bomb"))
            seeded = session.get(base + "/seed")
            check("duplicate_set_cookie_preserved", len(seeded.raw.headers.getlist("set-cookie")) == 5)
            check("real_response_cookie_jar", seeded.cookies.get("root") == "one" and seeded.cookies.get("only") == "path")
            cookies = session.get(base + "/scope/echo").json()["headers"].get("cookie", "")
            check("cookie_path_matches", "root=one" in cookies and "only=path" in cookies)
            root_cookie = session.get(base + "/echo").json()["headers"].get("cookie", "")
            check("cookie_path_domain_secure_expiry", "root=one" in root_cookie and all(x not in root_cookie for x in ("only=", "secure=", "wrong=", "expired=")))
            auth = {"Authorization": "Bearer owned", "Proxy-Authorization": "Basic owned", "Cookie2": "extra=owned"}
            same = session.get(base + "/same", headers=auth)
            check("same_origin_redirect_auth", same.json()["headers"].get("authorization") == "Bearer owned")
            check("redirect_cookie_and_history", len(same.history) == 1 and "redirect=retained" in same.json()["headers"].get("cookie", ""))
            cross = session.get(base + "/cross", headers=auth)
            received = {k.lower(): v for k, v in cross.json()["headers"].items()}
            check("cross_origin_redirect_no_credentials", not any(k in received for k in ("authorization", "proxy-authorization", "cookie", "cookie2")))
            triple = session.get(base + "/cross-chain", headers=auth)
            triple_headers = {k.lower(): v for k, v in triple.json()["headers"].items()}
            check("cross_then_same_cannot_repopulate_credentials", len(triple.history) == 2 and not any(k in triple_headers for k in ("authorization", "proxy-authorization", "cookie2")) and "root=one" not in triple_headers.get("cookie", ""))
            returned = session.get(base + "/return-chain", headers=auth)
            returned_headers = {k.lower(): v for k, v in returned.json()["headers"].items()}
            check("cross_then_return_cannot_repopulate_credentials", len(returned.history) == 3 and not any(k in returned_headers for k in ("authorization", "proxy-authorization", "cookie2")) and "root=one" not in returned_headers.get("cookie", ""))
            login = session.get(base + "/cross-login", headers=auth).json()["headers"]
            check("new_destination_cookies_survive_same_origin_hop", login.get("cookie") == "own_b=fresh")
            check("new_destination_cookie_security_path_rules", not any(k.lower() in ("authorization", "proxy-authorization", "cookie2") for k in login))
            expired = session.get(base + "/cross-expire", headers=auth).json()["headers"]
            check("redirect_local_cookie_deletion", "cookie" not in expired)
            before = len(calls)
            unfollowed = session.get(base + "/same", allow_redirects=False)
            check("allow_redirects_false_one_hop", unfollowed.status_code == 302 and len(calls) == before + 1)
            session.max_redirects = 2
            before = len(calls)
            rejects("requests_redirect_limit", requests.TooManyRedirects, lambda: session.get(base + "/loop"))
            check("redirect_count_not_bypassed", len(calls) == before + 3)
            replay = session.post(base + "/307", data=raw, headers={"Content-Type": "application/octet-stream"}).json()
            check("307_preserves_method_and_bytes", replay["method"] == "POST" and base64.b64decode(replay["body"]) == raw)
            rejects("reject_stream", UnsupportedFeature, lambda: session.get(base, stream=True))
            rejects("reject_multipart", UnsupportedFeature, lambda: session.post(base, files={"f": ("owned.txt", b"owned")}))
            rejects("reject_body_iterator", UnsupportedFeature, lambda: session.post(base, data=iter([b"owned"])))
            rejects("reject_verify_false", UnsupportedFeature, lambda: session.get(base, verify=False))
            rejects("reject_custom_ca", UnsupportedFeature, lambda: session.get(base, verify="owned-ca.pem"))
            rejects("reject_custom_proxy", UnsupportedFeature, lambda: session.get(base, proxies={"http": base}))
            rejects("reject_host_header", UnsupportedFeature, lambda: session.get(base, headers={"Host": "changed.invalid"}))
            rejects("reject_zero_timeout", UnsupportedFeature, lambda: session.get(base, timeout=0))
            rejects("reject_unbounded_timeout_pair", UnsupportedFeature, lambda: session.get(base, timeout=(None, 1)))
            rejects("reject_oversize_request", BodyLimitError, lambda: session.post(base, data=b"x" * (MAX_BODY + 1)))
            rejects("reject_custom_mount", UnsupportedFeature, lambda: session.mount("http://", requests.adapters.HTTPAdapter()))
        rejects("requires_explicit_call_context", requests.RequestException, lambda: session.get(base))

        def fake(envelope, _):
            return {"version": 1, "callId": envelope["callId"], "requestId": envelope["requestId"],
                    "url": envelope["url"], "status": 200, "reason": "OK",
                    "headers": [["Content-Length", "2"]], "body": b"{}"}

        def mutated(change):
            def bridge(envelope, context):
                value = fake(envelope, context)
                change(value)
                return value
            with BridgeSession(bridge) as custom, custom.call(CallContext(5)):
                return custom.get(base)

        for name, change in {
            "response_url_mismatch": lambda v: v.update(url=base + "/silent-redirect"),
            "response_call_id_mismatch": lambda v: v.update(callId="0" * 32),
            "response_request_id_mismatch": lambda v: v.update(requestId="0" * 32),
            "response_extra_field": lambda v: v.update(extra=True),
            "response_bool_status": lambda v: v.update(status=True),
            "response_header_injection": lambda v: v.update(headers=[["X-Test", "yes\r\nX-Other: no"]]),
            "response_duplicate_length": lambda v: v.update(headers=[["Content-Length", "2"], ["content-length", "2"]]),
            "response_header_limit": lambda v: v.update(headers=[["X-Test", "x" * 32768]]),
            "response_body_type": lambda v: v.update(body=[123, 125]),
            "response_length_mismatch": lambda v: v.update(body=b"bad"),
            "response_invalid_length": lambda v: v.update(headers=[["Content-Length", "-1"]]),
        }.items():
            rejects(name, BridgeProtocolError, lambda change=change: mutated(change))

        late_session = BridgeSession(lambda e, c: http_bridge(e, c, ignore_cancel=True))
        context = CallContext(2)
        timer = threading.Timer(0.03, context.cancel)
        with late_session.call(context):
            timer.start()
            rejects("cancelled_late_response_not_delivered", CallCancelled, lambda: late_session.get(base + "/slow"))
        timer.join()
        check("late_cookie_not_stored", late_session.cookies.get("late") is None)
        with late_session.call(CallContext(1)):
            check("next_call_after_cancel_can_succeed", late_session.get(base + "/echo").status_code == 200)
        # This bridge deliberately outlives the call budget; adapter must reject.
        def ignores_deadline(envelope, context):
            copied = {**envelope, "connectTimeoutMs": 1000, "readTimeoutMs": 1000}
            return http_bridge(copied, context, ignore_cancel=True)
        with BridgeSession(ignores_deadline) as slow, slow.call(CallContext(0.03)):
            rejects("expired_late_response_not_delivered", requests.Timeout, lambda: slow.get(base + "/slow"))
        with BridgeSession(ignores_deadline) as slow, slow.call(CallContext(0.09)):
            start = len(calls)
            rejects("total_deadline_spans_redirects", requests.Timeout, lambda: slow.get(base + "/slow-redirect"))
            hops = calls[start:]
            check("redirect_call_id_stable_request_id_unique", len(hops) == 2 and len({h["callId"] for h in hops}) == 1 and len({h["requestId"] for h in hops}) == 2 and hops[1]["deadlineRemainingMs"] < hops[0]["deadlineRemainingMs"])
        cancelled = CallContext(1)
        cancelled.cancel()
        before = len(calls)
        rejects("pre_cancelled_call_rejected", CallCancelled, lambda: late_session.call(cancelled).__enter__())
        check("pre_cancelled_call_no_network", len(calls) == before)
        for kind, exception in (("timeout", requests.Timeout), ("connection", requests.ConnectionError), ("tls", requests.exceptions.SSLError), ("cancelled", CallCancelled)):
            def failing(_, __, kind=kind):
                raise BridgeTransportError(kind)
            with BridgeSession(failing) as broken, broken.call(CallContext(1)):
                rejects("native_error_" + kind, exception, lambda: broken.get(base))
        import requests_adapter as owned_adapter
        original_decode = owned_adapter._decoded_body
        entered, released = threading.Event(), threading.Event()
        closing = BridgeSession(fake)
        def during_decode(*values):
            entered.set()
            if not released.wait(2):
                raise AssertionError("Close race fixture did not release")
            return original_decode(*values)
        def close_validation():
            if entered.wait(2):
                closing.close()
            released.set()
        owner = threading.Thread(target=close_validation)
        try:
            owned_adapter._decoded_body = during_decode
            owner.start()
            with closing.call(CallContext(3)):
                rejects("close_during_validation_discards_response", CallCancelled, lambda: closing.get(base))
        finally:
            released.set()
            owner.join(2)
            owned_adapter._decoded_body = original_decode
            closing.close()
        late_session.close()
        with late_session.call(CallContext(1)):
            rejects("closed_adapter_rejects", requests.RequestException, lambda: late_session.get(base))
        completed = True
    finally:
        session.close()
        for server in servers:
            server.shutdown()
            server.server_close()
        report = {"passed": completed and all(c["passed"] for c in checks), "checks": checks,
                  "scope": "Owned Python host/loopback bridge only", "native_transport_tested": False,
                  "ios_tested": False, "hard_cancellation_tested": False, "inputs": inputs,
                  "source_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (Path(__file__), HERE / "requests_adapter.py")}}
        (out / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"passed": True, "checks": len(checks), "report": str(out / "result.json")}, ensure_ascii=False))


if __name__ == "__main__":
    main()
