"""Fixed owned iOS fixture; no script/module/path execution supplied by callers."""
import base64
import json
import time
from urllib.parse import parse_qs, urlsplit

import requests
from urllib3.response import HTTPResponse
from requests_adapter import BridgeSession, CallContext, CallCancelled

CHECKS = (
    "transport_real_response",
    "transport_binary_bytes",
    "transport_json_body",
    "transport_form_body",
    "transport_cookie_duplicates",
    "transport_cookie_path_secure",
    "transport_cross_origin_strips_inherited",
    "transport_cross_origin_new_cookie",
    "transport_deadline",
    "transport_cancelled_wait",
    "transport_after_cancel_recovery",
    "transport_closed_adapter",
)
CANCEL_CALL_ID = "cccccccccccccccccccccccccccccccc"


def run(bridge, origins):
    if not callable(bridge) or not isinstance(origins, list) or len(origins) != 2:
        raise ValueError("Invalid owned transport probe input")
    for origin in origins:
        value = urlsplit(origin)
        token = value.path.removeprefix("/")
        if (value.scheme != "http" or value.hostname != "127.0.0.1" or not value.port
                or value.username or value.password or value.query or value.fragment
                or len(token) != 32 or any(c not in "0123456789abcdef" for c in token)):
            raise ValueError("Invalid owned loopback origin")
    if urlsplit(origins[0]).port == urlsplit(origins[1]).port:
        raise ValueError("Owned origins must use different listeners")
    checks = []
    traces = []

    def checked_bridge(envelope, context):
        traces.append({"callId": envelope["callId"], "requestId": envelope["requestId"],
                       "url": envelope["url"], "headers": dict(envelope["headers"])})
        return bridge(envelope, context)

    def check(name, condition):
        if name not in CHECKS or any(item["name"] == name for item in checks):
            raise AssertionError("Unexpected fixture check")
        checks.append({"name": name, "passed": bool(condition)})
        if not condition:
            raise AssertionError(name)

    first, second = origins
    session = BridgeSession(checked_bridge)
    try:
        with session.call(CallContext(12)):
            response = session.get(first + "/echo")
            check("transport_real_response", isinstance(response, requests.Response)
                  and isinstance(response.raw, HTTPResponse) and response.status_code == 200
                  and response.json()["method"] == "GET")
            binary = session.get(first + "/binary", headers={"Range": "bytes=0-5"})
            uploaded = session.post(first + "/echo", data=bytes((0, 255, 128, 13, 10, 65)),
                                    headers={"Content-Type": "application/octet-stream"}).json()
            check("transport_binary_bytes", binary.status_code == 206
                  and binary.content == bytes((0, 255, 128, 13, 10, 65))
                  and binary.headers["Content-Range"] == "bytes 0-5/6"
                  and binary.headers["X-Fixture"] == "bytes"
                  and uploaded["method"] == "POST"
                  and base64.b64decode(uploaded["body"]) == bytes((0, 255, 128, 13, 10, 65)))
            payload = {"text": "本机桥接", "value": [0, 255]}
            echo = session.post(first + "/echo", json=payload).json()
            check("transport_json_body", echo["method"] == "POST"
                  and json.loads(base64.b64decode(echo["body"])) == payload)
            form = session.post(first + "/echo", data={"item": ["a", "b"], "text": "表单"}).json()
            check("transport_form_body", parse_qs(base64.b64decode(form["body"]).decode())
                  == {"item": ["a", "b"], "text": ["表单"]})
            seed = session.get(first + "/seed")
            check("transport_cookie_duplicates", len(seed.raw.headers.getlist("set-cookie")) == 4
                  and session.cookies.get("root") == "one" and session.cookies.get("expires_cookie") == "yes")
            scoped = session.get(first + "/scope/echo").json()["headers"].get("cookie", "")
            top = session.get(first + "/echo").json()["headers"].get("cookie", "")
            check("transport_cookie_path_secure", "root=one" in scoped and "only=path" in scoped
                  and "only=path" not in top and "secure_only=" not in scoped and "secure_only=" not in top)
            start = len(traces)
            crossed = session.get(first + "/cross", headers={"Authorization": "Bearer owned-transport"})
            hops = traces[start:]
            check("transport_cross_origin_strips_inherited", len(hops) == 3
                  and hops[0]["headers"].get("authorization") == "Bearer owned-transport"
                  and not any(name in hops[1]["headers"] for name in ("authorization", "cookie", "cookie2", "proxy-authorization")))
            destination = crossed.json()["headers"]
            check("transport_cross_origin_new_cookie", crossed.url == second + "/echo"
                  and len(crossed.history) == 2 and destination.get("cookie") == "own_b=two"
                  and not any(name in destination for name in ("authorization", "cookie2", "proxy-authorization")))
        timed_out = False
        started = time.monotonic()
        with session.call(CallContext(0.05)):
            try:
                session.get(first + "/slow", timeout=1)
            except requests.Timeout:
                timed_out = True
        check("transport_deadline", timed_out and time.monotonic() - started < 2)
        cancelled = False
        started = time.monotonic()
        with session.call(CallContext(3, call_id=CANCEL_CALL_ID)):
            try:
                session.get(first + "/slow", timeout=2)
            except CallCancelled:
                cancelled = True
        check("transport_cancelled_wait", cancelled and time.monotonic() - started < 2)
        with session.call(CallContext(3)):
            check("transport_after_cancel_recovery", session.get(first + "/echo").status_code == 200)
        session.close()
        rejected = False
        with session.call(CallContext(1)):
            try:
                session.get(first + "/echo")
            except requests.RequestException:
                rejected = True
        check("transport_closed_adapter", rejected)
    finally:
        session.close()
    if tuple(item["name"] for item in checks) != CHECKS:
        raise AssertionError("Incomplete transport fixture")
    return {"version": 1, "checks": checks, "passed": all(item["passed"] for item in checks)}
