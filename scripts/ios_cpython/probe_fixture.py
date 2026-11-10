"""Owned synthetic fixture. No real subscription, external service or media."""
import sys


def _checkpoint(phase):
    path = getattr(sys, "_marco_probe_progress", None)
    if path:
        with open(path, "a", encoding="utf-8") as output:
            output.write(phase + "\n")
            output.flush()


_checkpoint("import_hashlib")
import hashlib
_checkpoint("import_importlib")
import importlib
_checkpoint("import_importlib_metadata")
import importlib.metadata
_checkpoint("import_io")
import io
_checkpoint("import_json")
import json
_checkpoint("import_os")
import os
_checkpoint("import_pathlib")
from pathlib import Path
_checkpoint("import_socket")
import socket
_checkpoint("import_ssl")
import ssl
_checkpoint("import_threading")
import threading
_checkpoint("import_time")
import time
_checkpoint("import_http_server")
from http.server import BaseHTTPRequestHandler, HTTPServer
_checkpoint("import_urllib_parse")
from urllib.parse import parse_qs, urlencode, urlsplit
_checkpoint("import_urllib_request")
from urllib.request import ProxyHandler, Request, build_opener
_checkpoint("fixture_imported")


class LocalFixture(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def send_body(self, body, kind="application/json; charset=utf-8", headers=None):
        if not isinstance(body, bytes):
            body = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        try:
            self.wfile.write(body)
        except ConnectionError:
            pass  # Expected for the client's explicit timeout fixture.

    def do_GET(self):
        parsed = urlsplit(self.path)
        query = parse_qs(parsed.query)
        if parsed.path == "/slow":
            time.sleep(0.25)
            self.send_body({"ok": True})
        elif parsed.path == "/catalog":
            self.send_body({"class": [{"type_id": "films", "type_name": "电影"}],
                            "list": [{"vod_id": "opaque/$#?中文", "vod_name": "本机示例"}],
                            "page": int(query.get("page", [1])[0]), "pagecount": 2})
        elif parsed.path == "/search":
            self.send_body({"list": [{"vod_id": "opaque/$#?中文", "vod_name": query["q"][0]}]})
        elif parsed.path == "/detail":
            self.send_body({"list": [{"vod_id": query["id"][0], "vod_name": "本机示例",
                            "vod_play_from": "local", "vod_play_url": "第一集$episode-1"}]})
        elif parsed.path == "/play":
            self.send_body({"parse": 0, "url": self.server.origin + "/media.m3u8"})
        elif parsed.path == "/media.m3u8":
            self.send_body(b"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-ENDLIST\n", "application/vnd.apple.mpegurl")
        elif parsed.path == "/cookie":
            self.send_body({"ok": True}, headers={"Set-Cookie": "fixture=one; Path=/; HttpOnly"})
        elif parsed.path == "/echo-cookie":
            self.send_body({"cookie": self.headers.get("Cookie", "")})
        elif parsed.path == "/page":
            self.send_body('<main><a class="item" href="/detail?id=1">中文影片</a></main>'.encode(), "text/html; charset=utf-8")
        else:
            self.send_error(404)

    def do_POST(self):
        size = int(self.headers.get("Content-Length", 0))
        if size > 4096:
            self.send_error(413)
            return
        self.send_body({"body": json.loads(self.rfile.read(size)),
                        "content_type": self.headers.get("Content-Type", "")})


class Spider:
    """Real CPython calls with a familiar source ABI, using urllib in-process."""
    def init(self, extend):
        self.origin = extend["origin"]
        self.opener = build_opener(ProxyHandler({}))

    def fetch(self, path, params=None):
        url = self.origin + path
        if params:
            url += "?" + urlencode(params)
        with self.opener.open(url, timeout=2) as response:
            return json.loads(response.read().decode("utf-8"))

    def homeContent(self, filter=False):
        return self.fetch("/catalog")

    def homeVideoContent(self):
        return self.fetch("/catalog")

    def categoryContent(self, tid, pg, filter, extend):
        if tid != "films" or extend:
            raise ValueError("Synthetic fixture supports the films category without filters")
        return self.fetch("/catalog", {"page": pg})

    def searchContent(self, key, quick=False, pg="1"):
        return self.fetch("/search", {"q": key, "page": pg})

    def detailContent(self, ids):
        return self.fetch("/detail", {"id": ids[0]})

    def playerContent(self, flag, id, vipFlags=None):
        if flag != "local" or id != "episode-1":
            raise ValueError("Unknown fixture episode")
        return self.fetch("/play")


def run_probe(root):
    _checkpoint("run_probe")
    checks = []

    def check(name, passed):
        checks.append({"name": name, "passed": bool(passed)})
        _checkpoint("check:" + name + ":" + str(bool(passed)))
        if not passed:
            raise AssertionError(name)

    check("io_utf8", io.StringIO("中文✓").read() == "中文✓")
    check("io_binary", io.BytesIO(bytes([0, 255, 3])).read() == b"\x00\xff\x03")
    check("json_utf8", json.loads(json.dumps({"name": "中文"}, ensure_ascii=False))["name"] == "中文")
    check("hashlib_sha256", hashlib.sha256(b"abc").hexdigest() == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    work = Path(root) / "source-a"
    work.mkdir(parents=True, exist_ok=True)
    file = work / "中文.json"
    file.write_text('{"name":"中文"}', encoding="utf-8")
    check("os_path_local_file", os.path.basename(file) == "中文.json" and json.loads(file.read_text(encoding="utf-8"))["name"] == "中文")
    check("ssl_context", ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT).verify_mode == ssl.CERT_REQUIRED)
    if sys.platform == "ios":
        # The native host has explicitly ignored SIGPIPE. Exercise the ordinary
        # socket path without MSG_NOSIGNAL or an exception-hiding request shim.
        left, right = socket.socketpair()
        try:
            right.close()
            try:
                left.sendall(b"closed-peer")
            except BrokenPipeError:
                check("closed_socket_raises_broken_pipe", True)
            else:
                check("closed_socket_raises_broken_pipe", False)
        finally:
            left.close()
            right.close()
    extension_origins = {}
    for name in ("_socket", "_ssl", "_hashlib", "_json", "_elementtree", "pyexpat", "zlib", "_sqlite3"):
        module = importlib.import_module(name)
        extension_origins[name] = {"file": getattr(module, "__file__", None), "origin": module.__spec__.origin}
        check("stdlib_extension_" + name, module is not None)
        if sys.platform == "ios":
            check("ios_framework_" + name, ".framework/" in (module.__spec__.origin or ""))

    _checkpoint("import_requests")
    import requests
    _checkpoint("import_bs4")
    from bs4 import BeautifulSoup
    _checkpoint("import_certifi")
    import certifi
    check("certifi_trust_store", ssl.create_default_context(cafile=certifi.where()).cert_store_stats()["x509_ca"] > 0)
    soup = BeautifulSoup('<div><a class="item" data-n="1">中文</a><a>other</a></div>', "html.parser")
    check("bs4_html_parser_css", soup.select_one("a.item[data-n='1']").get_text() == "中文")

    server = HTTPServer(("127.0.0.1", 0), LocalFixture)
    server.origin = "http://127.0.0.1:" + str(server.server_port)
    thread = threading.Thread(target=server.serve_forever, name="owned-loopback-fixture")
    thread.start()
    try:
        spider = Spider()
        spider.init({"origin": server.origin})
        home = spider.homeContent(True)
        check("spider_home", home["class"][0]["type_name"] == "电影")
        check("spider_home_vod", spider.homeVideoContent()["list"][0]["vod_name"] == "本机示例")
        check("spider_category_pagination", spider.categoryContent("films", "2", False, {})["page"] == 2)
        check("spider_search_chinese", spider.searchContent("中文查询")["list"][0]["vod_name"] == "中文查询")
        detail = spider.detailContent(["opaque/$#?中文"])["list"][0]
        check("spider_detail_opaque_id", detail["vod_id"] == "opaque/$#?中文")
        check("spider_detail_episodes", detail["vod_play_url"] == "第一集$episode-1")
        player = spider.playerContent("local", "episode-1", [])
        check("spider_play_parse", player["parse"] == 0 and player["url"].startswith(server.origin))
        with spider.opener.open(player["url"], timeout=2) as response:
            check("synthetic_manifest_prefix", response.read(8) == b"#EXTM3U\n")
        with requests.Session() as session:
            session.trust_env = False
            response = session.get(server.origin + "/catalog", timeout=2)
            check("requests_json", response.json()["list"][0]["vod_name"] == "本机示例")
            session.get(server.origin + "/cookie", timeout=2).raise_for_status()
            check("requests_session_cookie", session.get(server.origin + "/echo-cookie", timeout=2).json()["cookie"] == "fixture=one")
            echo = session.post(server.origin + "/echo", json={"title": "中文"}, timeout=2).json()
            check("requests_post_unicode", echo["body"]["title"] == "中文" and echo["content_type"].startswith("application/json"))
            page = session.get(server.origin + "/page", timeout=2)
            check("requests_bs4_combined", BeautifulSoup(page.text, "html.parser").select_one("a.item").get_text() == "中文影片")
            started = time.monotonic()
            try:
                session.get(server.origin + "/slow", timeout=0.05)
            except requests.exceptions.Timeout:
                check("requests_bounded_read_timeout", time.monotonic() - started < 1.5)
            else:
                check("requests_bounded_read_timeout", False)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
    check("fixture_thread_joined", not thread.is_alive())
    return json.dumps({"passed": True, "checks": checks, "runtime": sys.version,
        "platform": sys.platform, "ssl": ssl.OPENSSL_VERSION, "extension_origins": extension_origins,
        "dependencies": {name: importlib.metadata.version(name) for name in (
            "requests", "beautifulsoup4", "urllib3", "certifi", "charset-normalizer", "idna", "soupsieve", "typing-extensions")},
        "scope": "Owned local protocol fixture only; no external source, real media decoding or TLS handshake"}, ensure_ascii=False)
