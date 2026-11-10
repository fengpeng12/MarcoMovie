"""Experimental bounded requests transport contract; no native networking here.

The injected bridge performs exactly one HTTP hop. Session retains requests'
redirect/cookie logic. Cancellation is cooperative, never a native hard interrupt.
"""
from __future__ import annotations

from contextlib import contextmanager
from contextvars import ContextVar
from email.message import Message
import io
import math
import re
import threading
import time
from types import SimpleNamespace
from urllib.parse import urlsplit, urlunsplit
import uuid
import zlib

import requests
from requests.adapters import HTTPAdapter
from requests.cookies import RequestsCookieJar, extract_cookies_to_jar
from requests.exceptions import RequestException, Timeout, ConnectionError, SSLError
from urllib3._collections import HTTPHeaderDict
from urllib3.response import HTTPResponse

MAX_BODY = 6 * 1024 * 1024
MAX_HEADERS = 32768
MAX_HEADER_COUNT = 128
_TOKEN = re.compile(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$")
_CONTROL = re.compile(r"[\x00-\x08\x0a-\x1f\x7f]")
_IDENTITY = re.compile(r"^[0-9a-f]{32}$")
_METHODS = frozenset(("GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"))


class UnsupportedFeature(RequestException):
    pass


class BridgeProtocolError(RequestException):
    pass


class CallCancelled(RequestException):
    pass


class BodyLimitError(RequestException):
    pass


class BridgeTransportError(Exception):
    """Native bridge failure categories, with no server body/credential text."""
    def __init__(self, kind: str):
        if kind not in ("timeout", "cancelled", "connection", "tls"):
            raise ValueError("Unknown transport error kind")
        self.kind = kind
        super().__init__(kind)


class CallContext:
    """One Spider operation identity/deadline, shared by all its HTTP hops.

    cancel() records intent only. The future native owner must separately cancel
    its tasks and acknowledge eventual completion; no thread is killed here.
    """
    def __init__(self, budget_seconds: float, *, call_id: str | None = None):
        if (isinstance(budget_seconds, bool) or not isinstance(budget_seconds, (int, float))
                or not math.isfinite(budget_seconds) or not 0 < budget_seconds <= 45):
            raise ValueError("Call budget must be finite and at most 45 seconds")
        self.call_id = call_id or uuid.uuid4().hex
        if not isinstance(self.call_id, str) or not _IDENTITY.fullmatch(self.call_id):
            raise ValueError("Invalid call identity")
        self.deadline = time.monotonic() + budget_seconds
        self._cancelled = threading.Event()

    def cancel(self):
        self._cancelled.set()

    @property
    def cancelled(self):
        return self._cancelled.is_set()

    def check(self):
        if self.cancelled:
            raise CallCancelled("Python source HTTP call cancelled")
        if time.monotonic() >= self.deadline:
            raise Timeout("Python source HTTP call deadline exceeded")

    def remaining_ms(self):
        self.check()
        return max(1, math.ceil((self.deadline - time.monotonic()) * 1000))


def _url(value):
    if not isinstance(value, str) or len(value) > 16384 or re.search(r"[\x00-\x20\x7f]", value):
        raise BridgeProtocolError("Invalid HTTP URL")
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError as error:
        raise BridgeProtocolError("Invalid HTTP URL") from error
    if (parsed.scheme not in ("http", "https") or not parsed.hostname
            or parsed.username is not None or parsed.password is not None
            or port is not None and not 0 < port <= 65535):
        raise UnsupportedFeature("Only HTTP(S) URLs without userinfo are supported")
    return urlunsplit((parsed.scheme, parsed.netloc, parsed.path or "/", parsed.query, ""))


def _origin(value):
    parsed = urlsplit(_url(value))
    return parsed.scheme, parsed.hostname.lower(), parsed.port or (443 if parsed.scheme == "https" else 80)


def _headers(pairs, *, response=False):
    if not isinstance(pairs, (list, tuple)) or len(pairs) > MAX_HEADER_COUNT:
        raise BridgeProtocolError("Invalid HTTP header list")
    clean, seen, size = [], set(), 0
    for pair in pairs:
        if not isinstance(pair, (list, tuple)) or len(pair) != 2:
            raise BridgeProtocolError("Invalid HTTP header pair")
        name, value = pair
        if (not isinstance(name, str) or not _TOKEN.fullmatch(name)
                or not isinstance(value, str) or _CONTROL.search(value)):
            raise BridgeProtocolError("Invalid HTTP header name or value")
        try:
            size += len(name.encode("ascii")) + len(value.encode("latin-1")) + 4
        except UnicodeError as error:
            raise BridgeProtocolError("HTTP headers require ASCII names and Latin-1 values") from error
        if size > MAX_HEADERS:
            raise BridgeProtocolError("HTTP headers exceed limit")
        name = name.lower()
        if name in seen and (not response or name in ("content-length", "location", "content-encoding", "transfer-encoding")):
            raise BridgeProtocolError("Duplicate singleton HTTP header")
        seen.add(name)
        clean.append([name, value])
    if response and "content-length" in seen and "transfer-encoding" in seen:
        raise BridgeProtocolError("Ambiguous HTTP response framing")
    for name, value in clean:
        if name == "content-length" and not re.fullmatch(r"[0-9]+", value):
            raise BridgeProtocolError("Invalid HTTP Content-Length")
    return clean


def _timeout(value, remaining):
    if value is None:
        values = (10.0, 10.0)
    elif isinstance(value, tuple) and len(value) == 2:
        values = value
    elif isinstance(value, (int, float)) and not isinstance(value, bool):
        values = (value, value)
    else:
        raise UnsupportedFeature("Timeout requires a positive number or connect/read pair")
    result = []
    for item in values:
        if (isinstance(item, bool) or not isinstance(item, (int, float))
                or not math.isfinite(item) or item <= 0):
            raise UnsupportedFeature("Unbounded or invalid HTTP timeouts are unsupported")
        result.append(min(remaining, max(1, math.ceil(item * 1000))))
    return result


def _decoded_body(body, headers, method, status):
    if len(body) > MAX_BODY:
        raise BodyLimitError("HTTP response exceeds 6 MiB")
    if method == "HEAD" or status in (204, 304):
        if body:
            raise BridgeProtocolError("Body forbidden for this response")
        return b""
    values = dict(headers)
    length = values.get("content-length")
    if length is not None and (not re.fullmatch(r"[0-9]+", length) or int(length) != len(body)):
        raise BridgeProtocolError("HTTP response length mismatch")
    transfer = values.get("transfer-encoding", "").lower()
    if transfer not in ("", "chunked"):
        raise UnsupportedFeature("Unsupported transfer encoding")
    encoding = values.get("content-encoding", "identity").lower().strip()
    if encoding in ("", "identity"):
        return body
    if encoding not in ("gzip", "deflate"):
        raise UnsupportedFeature("Unsupported content encoding")
    try:
        decoder = zlib.decompressobj(31 if encoding == "gzip" else zlib.MAX_WBITS)
        output = decoder.decompress(body, MAX_BODY + 1)
        if len(output) > MAX_BODY or decoder.unconsumed_tail:
            raise BodyLimitError("Decoded HTTP response exceeds 6 MiB")
        if not decoder.eof or decoder.unused_data:
            raise BridgeProtocolError("Incomplete or concatenated compressed response")
        return output
    except zlib.error as error:
        raise BridgeProtocolError("Invalid compressed HTTP response") from error


class RequestsBridgeAdapter(HTTPAdapter):
    """Inject a one-hop callable; never falls back to Python socket networking."""
    def __init__(self, bridge):
        if not callable(bridge):
            raise TypeError("bridge must be callable")
        # No poolmanager is constructed: every send must go through the bridge.
        self._bridge = bridge
        self._context = ContextVar("movie_python_http_call", default=None)
        self._closed = False

    @contextmanager
    def call(self, context):
        if not isinstance(context, CallContext):
            raise TypeError("Explicit CallContext required")
        context.check()
        token = self._context.set(context)
        try:
            yield
        finally:
            self._context.reset(token)

    def close(self):
        self._closed = True

    def send(self, request, stream=False, timeout=None, verify=True, cert=None, proxies=None):
        context = self._context.get()
        if self._closed:
            raise RequestException("Python source HTTP adapter is closed")
        if context is None:
            raise RequestException("HTTP request requires an active source call")
        context.check()
        if stream is not False:
            raise UnsupportedFeature("Streaming HTTP responses are unsupported")
        if verify is not True or cert is not None or proxies:
            raise UnsupportedFeature("Custom TLS, certificates and proxies are unsupported")
        method = request.method
        if method not in _METHODS:
            raise UnsupportedFeature("Unsupported HTTP method")
        url = _url(request.url)
        body = request.body
        if body is None:
            body = b""
        elif isinstance(body, str):
            body = body.encode("utf-8")
        elif isinstance(body, (bytes, bytearray)):
            body = bytes(body)
        else:
            raise UnsupportedFeature("Streaming/file/custom HTTP bodies are unsupported")
        if len(body) > MAX_BODY:
            raise BodyLimitError("HTTP request exceeds 6 MiB")
        if body and method in ("GET", "HEAD"):
            raise UnsupportedFeature("GET/HEAD request bodies are unsupported")
        headers = _headers(list(request.headers.items()))
        clean = []
        for name, value in headers:
            if name == "content-type" and value.lower().startswith("multipart/"):
                raise UnsupportedFeature("Multipart HTTP requests are unsupported")
            if name == "content-length":
                if not value.isascii() or not value.isdigit() or int(value) != len(body):
                    raise BridgeProtocolError("HTTP request length mismatch")
                continue  # The transport derives framing from exact bytes.
            if name == "connection" and value.lower() in ("keep-alive", "close"):
                continue  # Buffered transport owns connection lifetime.
            if name in ("host", "connection", "transfer-encoding", "upgrade", "trailer", "te", "proxy-connection"):
                raise UnsupportedFeature("Custom HTTP transport/framing headers are unsupported")
            clean.append([name, value])
        remaining = context.remaining_ms()
        connect, read = _timeout(timeout, remaining)
        envelope = {"version": 1, "callId": context.call_id, "requestId": uuid.uuid4().hex,
                    "url": url, "method": method, "headers": clean, "body": body,
                    "connectTimeoutMs": connect, "readTimeoutMs": read,
                    "deadlineRemainingMs": remaining}
        try:
            value = self._bridge(envelope, context)
        except BridgeTransportError as error:
            context.check()
            types = {"timeout": Timeout, "cancelled": CallCancelled, "connection": ConnectionError, "tls": SSLError}
            raise types[error.kind]("Python HTTP transport " + error.kind, request=request) from error
        context.check()  # Never deliver a cancelled/expired callback, even if bridge ignored it.
        if self._closed:
            raise CallCancelled("Python HTTP source closed during request")
        required = {"version", "callId", "requestId", "url", "status", "reason", "headers", "body"}
        if not isinstance(value, dict) or set(value) != required:
            raise BridgeProtocolError("Invalid HTTP bridge response fields")
        if (type(value["version"]) is not int or value["version"] != 1
                or value["callId"] != envelope["callId"] or value["requestId"] != envelope["requestId"]
                or value["url"] != url):
            raise BridgeProtocolError("Stale, mismatched or redirected HTTP bridge response")
        status, reason, wire = value["status"], value["reason"], value["body"]
        if (type(status) is not int or not 200 <= status <= 599 or not isinstance(reason, str)
                or len(reason) > 512 or _CONTROL.search(reason) or not isinstance(wire, bytes)):
            raise BridgeProtocolError("Invalid HTTP status, reason or body")
        headers = _headers(value["headers"], response=True)
        decoded = _decoded_body(wire, headers, method, status)
        context.check()
        message, raw_headers = Message(), HTTPHeaderDict()
        for name, text in headers:
            message[name] = text
            raw_headers.add(name, text)
        original = SimpleNamespace(msg=message)
        raw = HTTPResponse(body=io.BytesIO(wire), status=status, reason=reason, headers=raw_headers,
                           original_response=original, preload_content=False, decode_content=False,
                           request_method=method, request_url=url)
        response = self.build_response(request, raw)
        # Buffered-only profile: content is decoded with explicit expansion limits;
        # raw metadata remains real urllib3 metadata, including duplicate cookies.
        raw.close()
        response._content = decoded
        response._content_consumed = True
        response.url = url
        context.check()
        if self._closed:
            raise CallCancelled("Python HTTP source closed during response validation")
        return response


class BridgeSession(requests.Session):
    """Real requests Session, with strict same-origin redirect credentials."""
    def __init__(self, bridge):
        self._restricted_mount = False
        super().__init__()
        for adapter in self.adapters.values():
            adapter.close()
        self.adapters.clear()
        self.adapter = RequestsBridgeAdapter(bridge)
        self.mount("http://", self.adapter)
        self.mount("https://", self.adapter)
        self._restricted_mount = True
        self.trust_env = False
        self.max_redirects = 5
        self.headers["Accept-Encoding"] = "gzip, deflate"

    def mount(self, prefix, adapter):
        if getattr(self, "_restricted_mount", False):
            raise UnsupportedFeature("Custom HTTP adapters are unsupported")
        return super().mount(prefix, adapter)

    def rebuild_auth(self, prepared_request, response):
        super().rebuild_auth(prepared_request, response)
        previously_crossed = getattr(response.request, "_movie_crossed_origin", False)
        crossed = (previously_crossed
                   or _origin(prepared_request.url) != _origin(response.request.url))
        prepared_request._movie_crossed_origin = crossed
        if crossed:
            # requests prepares cookies again at every hop. A sticky marker is
            # necessary for A -> B -> B (or back to A), including differing ports.
            # Once crossed, only cookies newly set in this redirect chain by the
            # exact target origin are eligible. Keep real CookieJar parsing and
            # expiry/deletion semantics; do not drop destination login cookies.
            origin_jars = getattr(response.request, "_movie_redirect_cookies", {})
            if previously_crossed:
                jar = origin_jars.setdefault(_origin(response.request.url), RequestsCookieJar())
                extract_cookies_to_jar(jar, response.request, response.raw)
            prepared_request._movie_redirect_cookies = origin_jars
            for key in ("Authorization", "Proxy-Authorization", "Cookie", "Cookie2"):
                prepared_request.headers.pop(key, None)
            prepared_request.prepare_cookies(
                origin_jars.get(_origin(prepared_request.url), RequestsCookieJar()))

    def call(self, context):
        return self.adapter.call(context)
