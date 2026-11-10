"""Candidate host checks in one fresh process per source, using locked wheels.

No download, product dispatcher, mobile runtime or user endpoint is exercised.
"""
import argparse
import base64
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
HOST = ROOT / "android/src/main/assets/python-native"
TRANSPORT = ROOT / "scripts/ios_cpython_transport"
CASES = ("contract", "root_package", "network", "search_two", "search_error",
         "init_error", "init_deadline", "cancelled", "missing", "proxy", "limits",
         "proxy_limit", "release", "isolation_a", "isolation_b", "live")


def child(case, packages):
    sys.path[:0] = [str(HOST), str(TRANSPORT), str(packages)]
    import requests
    from host import NativePythonSource, SourceContractError, normalize_proxy, validate_package
    from requests_adapter import CallCancelled, UnsupportedFeature, MAX_BODY
    checks = []

    def check(name, value):
        if not value:
            raise AssertionError(name)
        if name in [item["name"] for item in checks]:
            raise AssertionError("Duplicate check")
        checks.append({"name": name, "passed": True})

    def rejects(name, fn, kind=Exception):
        try:
            fn()
        except kind:
            check(name, True)
        else:
            raise AssertionError(name + " unexpectedly succeeded")

    def no_network(*_):
        raise AssertionError("Unexpected network request")

    def source(code, **kwargs):
        return NativePythonSource("main.py", {"main.py": code.encode()}, bridge=no_network, **kwargs)

    check("locked_requests", Path(requests.__file__).is_relative_to(packages))
    if case == "contract":
        code = '''from base.spider import Spider as Base
from . import state
from .helper import answer, resource_info
import json
class Spider(Base):
    def __init__(self):
        state.constructions += 1
    def init(self, ext):
        state.inits += 1
        self.ext = ext
    def homeContent(self, filter):
        return json.dumps(dict(ext=self.ext, answer=answer, info=resource_info(),
            constructions=state.constructions, inits=state.inits, loads=state.loads, filter=filter))
    def homeVideoContent(self): return {"list": ["owned"]}
    def categoryContent(self, tid, pg, filter, extend): return dict(tid=tid, pg=pg, filter=filter, extend=extend)
    def detailContent(self, ids): return dict(ids=ids)
    def searchContent(self, word, quick, pg): return json.dumps(dict(word=word, quick=quick, pg=pg))
    def playerContent(self, flag, id, flags): return dict(flag=flag, id=id, flags=flags)
'''
        files = {"pkg/__init__.py": b"from . import state\nstate.loads += 1\n",
                 "pkg/state.py": b"loads=0\nconstructions=0\ninits=0\n",
                 "pkg/main.py": code.encode(), "pkg/data/own text.txt": "资源".encode(),
                 "pkg/helper.py": b'''import importlib.resources, pkgutil
answer=42
def resource_info():
    path=importlib.resources.files('pkg').joinpath('data', 'own text.txt')
    with path.open('r', encoding='utf-8') as stream: text=stream.read()
    return dict(text=text, bytes=list(path.read_bytes()), file=__file__,
        legacy=list(pkgutil.get_data('pkg', 'data/own text.txt')),
        children=[p.name for p in importlib.resources.files('pkg').iterdir()])
'''}
        raw = ' \n{"label":"原样", "padding": 1} \t'
        host = NativePythonSource("pkg/main.py", files, bridge=no_network, extension={"changed": True}, raw_extension=raw)
        first = host.invoke("home", [True])
        second = host.invoke("home", [False])
        check("raw_extension_preserved", first["ext"] == raw)
        check("single_construct_init_module", all(second[key] == 1 for key in ("loads", "inits", "constructions")))
        check("real_relative_import", first["answer"] == 42)
        check("package_text_resource", first["info"]["text"] == "资源")
        check("package_binary_resource", first["info"]["bytes"] == list("资源".encode()) == first["info"]["legacy"])
        check("opaque_file_origin", first["info"]["file"].startswith(host.origin) and "D:" not in first["info"]["file"])
        check("package_iterdir", "data" in first["info"]["children"])
        check("home_vod", host.invoke("homeVod", []) == {"list": ["owned"]})
        check("category_page_string", host.invoke("category", ["id", 7, True, {"year": "2026"}]) == dict(tid="id", pg="7", filter=True, extend={"year": "2026"}))
        check("detail_scalar_array", host.invoke("detail", ["a|b"]) == {"ids": ["a|b"]})
        ids = ["a", "b", "a"]
        check("detail_array_unmodified", host.invoke("detail", [ids]) == {"ids": ids})
        check("search_json_result", host.invoke("search", ["word", False, 3]) == dict(word="word", quick=False, pg="3"))
        check("play_arguments", host.invoke("play", ["flag", "opaque$id", ["x"]]) == dict(flag="flag", id="opaque$id", flags=["x"]))
        host.close()
    elif case == "live":
        host = source('''from base.spider import Spider as Base
import json
class Spider(Base):
 def liveContent(self,url):
  if url == 'text': return '#EXTM3U\\n#EXTINF:-1,Owned\\nrelative/stream.m3u8\\n'
  if url == 'empty': return ''
  return json.dumps({'url':url,'list':[]})
''')
        check("live_json_preserves_argument", host.invoke("liveContent", ["opaque/id"]) == {"url":"opaque/id","list":[]})
        check("live_m3u_preserves_text", host.invoke("liveContent", ["text"]) == '#EXTM3U\n#EXTINF:-1,Owned\nrelative/stream.m3u8\n')
        check("live_empty_preserved", host.invoke("liveContent", ["empty"]) == '')
        host.close()
    elif case == "root_package":
        files = {"__init__.py": b"from base.spider import Spider as Base\nfrom .helper import value\nclass Spider(Base):\n def homeContent(self,f): return dict(value=value,ext=self.extend)\n",
                 "helper.py": b"from .nested.leaf import value\n", "nested/leaf.py": b"value='namespace'\n"}
        host = NativePythonSource("__init__.py", files, bridge=no_network, extension={"x": [1, "中"]})
        check("root_package_namespace_import", host.invoke("home", [False]) == {"value": "namespace", "ext": '{"x":[1,"中"]}'})
        host.close()
    elif case == "network":
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self): self.reply()
            do_POST = do_GET
            def reply(self):
                content = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                payload = json.dumps({"path": self.path, "body": base64.b64encode(content).decode(),
                                      "cookie": self.headers.get("Cookie", "")}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                if self.path == "/seed": self.send_header("Set-Cookie", "retained=yes; Path=/")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers(); self.wfile.write(payload)
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        origin = "http://127.0.0.1:" + str(server.server_port)
        contexts, paths = [], []
        def bridge(envelope, context):
            context.check()
            parsed = urlsplit(envelope["url"])
            if parsed.hostname != "127.0.0.1" or parsed.port != server.server_port:
                raise AssertionError("Fixture bridge only allows its own server")
            contexts.append(envelope["callId"]); paths.append(parsed.path)
            conn = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=2)
            try:
                conn.request(envelope["method"], parsed.path, envelope["body"], dict(envelope["headers"]))
                reply = conn.getresponse()
                return dict(version=1, callId=envelope["callId"], requestId=envelope["requestId"],
                            url=envelope["url"], status=reply.status, reason=reply.reason,
                            headers=[list(pair) for pair in reply.getheaders()], body=reply.read())
            finally: conn.close()
        code = '''from base.spider import Spider as Base
import requests
from requests import Session
from requests.sessions import Session as Alias, HTTPAdapter
from requests.api import get as api_get
from requests_adapter import UnsupportedFeature
class OwnSession(Session): pass
retained=OwnSession()
class Spider(Base):
    def init(self,ext):
        self.origin=ext
        self.initReply=retained.get(ext+'/seed').json()
    def homeContent(self,f):
        values=[retained.get(self.origin+'/echo').json(), api_get(self.origin+'/echo').json(),
            requests.post(self.origin+'/echo', data=bytes([0,255,128,65])).json(),
            requests.post(self.origin+'/echo', json={'owned': True}).json(),
            requests.post(self.origin+'/echo', data={'space':'a b'}).json(),
            self.fetch(self.origin+'/echo').json()]
        try:
            HTTPAdapter().send(None)
        except UnsupportedFeature: blocked=True
        else: blocked=False
        return dict(values=values, alias=Session is Alias is requests.Session,
                    inherited=isinstance(retained,Session), blocked=blocked)
'''
        host = NativePythonSource("main.py", {"main.py": code.encode()}, bridge=bridge, extension=origin)
        try:
            for invalid in ("", True, 1, "a"*31, "A"*32, "a"*33, "a"*31+"\n"):
                rejects("invalid_operation_identity_" + repr(invalid),
                        lambda: host.invoke("home", [False], operation_id=invalid), SourceContractError)
            check("invalid_identity_does_not_initialize", host._state == "new" and not contexts)
            first = host.invoke("home", [False], operation_id="a"*32); split = len(contexts)
            second = host.invoke("home", [False], operation_id="b"*32)
            check("caller_identity_exact_first", set(contexts[:split]) == {"a"*32})
            check("caller_identity_exact_second", set(contexts[split:]) == {"b"*32})
            check("real_session_class_aliases", first["alias"] and first["inherited"])
            check("no_raw_httpadapter_alias", first["blocked"])
            check("retained_session_cookie", "retained=yes" in first["values"][0]["cookie"] and "retained=yes" in second["values"][0]["cookie"])
            check("fresh_api_session_cookie", first["values"][1]["cookie"] == "")
            check("arbitrary_request_bytes", base64.b64decode(first["values"][2]["body"]) == bytes([0,255,128,65]))
            check("real_json_post", json.loads(base64.b64decode(first["values"][3]["body"])) == {"owned": True})
            check("real_form_post", base64.b64decode(first["values"][4]["body"]) == b"space=a+b")
            check("base_fetch_bridge", first["values"][5]["path"] == "/echo")
            check("init_same_operation_identity", len(set(contexts[:split])) == 1 and paths.count("/seed") == 1)
            check("next_operation_new_context", len(set(contexts[split:])) == 1 and contexts[0] != contexts[-1])
            retained = sys.modules["main"].retained
            rejects("idle_session_send_rejected", lambda: retained.get(origin + "/echo"), SourceContractError)
            host.close()
            rejects("closed_session_send_rejected", lambda: retained.get(origin + "/echo"), SourceContractError)
        finally:
            host.close(); server.shutdown(); server.server_close(); thread.join(2)
    elif case in ("search_two", "search_error"):
        arguments = "self,word,quick" if case == "search_two" else "self,word,quick,pg='1'"
        body = "return dict(word=word,quick=quick,calls=self.calls)" if case == "search_two" else "raise TypeError('authored failure')"
        host = source("from base.spider import Spider as Base\nclass Spider(Base):\n calls=0\n def searchContent(" + arguments + "):\n  self.calls+=1\n  " + body + "\n")
        if case == "search_two":
            check("two_argument_search_once", host.invoke("search", ["word", True, 8]) == dict(word="word", quick=True, calls=1))
        else:
            rejects("authored_typeerror_propagated", lambda: host.invoke("search", ["word", False, 1]), TypeError)
            check("typeerror_not_replayed", host._spider.calls == 1)
            rejects("failed_source_not_retried", lambda: host.invoke("search", ["word", False, 1]), SourceContractError)
        host.close()
    elif case == "init_error":
        host = source("from base.spider import Spider as Base\nclass Spider(Base):\n calls=0\n def init(self,ext):\n  self.calls+=1\n  raise TypeError('init owned failure')\n")
        rejects("initialization_error", lambda: host.invoke("home", [True]), TypeError)
        rejects("initialization_never_replayed", lambda: host.invoke("home", [True]), SourceContractError)
        check("one_init_attempt", host._spider.calls == 1)
        host.close()
    elif case == "init_deadline":
        host = source("import time\nfrom base.spider import Spider as Base\ntime.sleep(.07)\nclass Spider(Base):\n calls=0\n def init(self,ext): self.calls+=1\n def homeContent(self,f): return {}\n")
        rejects("loading_init_same_budget", lambda: host.invoke("home", [True], budget=.02), requests.exceptions.Timeout)
        rejects("deadline_no_reinitialization", lambda: host.invoke("home", [True]), SourceContractError)
        check("no_claim_hard_interrupt", host._spider.calls == 1)
        host.close()
    elif case == "cancelled":
        signal = threading.Event(); contexts = []
        def late_bridge(envelope, context):
            contexts.append(context)
            signal.set()
            return dict(version=1, callId=envelope["callId"], requestId=envelope["requestId"],
                        url=envelope["url"], status=200, reason="OK", headers=[["Set-Cookie", "late=yes"]], body=b'{}')
        code = b"import requests\nfrom base.spider import Spider as Base\nsession=requests.Session()\nclass Spider(Base):\n def homeContent(self,f): return session.get('http://127.0.0.1:1/owned').json()\n"
        host = NativePythonSource("main.py", {"main.py": code}, bridge=late_bridge)
        rejects("late_cancelled_reply_rejected", lambda: host.invoke("home", [True], cancellation=signal.is_set), CallCancelled)
        check("cancelled_cookie_not_stored", list(sys.modules["main"].session.cookies) == [])
        check("caller_cancellation_in_context", contexts[0].cancelled)
        rejects("cancelled_source_not_reused", lambda: host.invoke("home", [True]), SourceContractError)
        host.close()
    elif case == "missing":
        host = source("from base.spider import Spider\n")
        rejects("missing_home_explicit", lambda: host.invoke("home", [False]), NotImplementedError)
        host.close()
    elif case == "proxy":
        code = '''from base.spider import Spider as Base
class Spider(Base):
    def playerContent(self,flag,id,flags):
        return dict(url=self.getProxyUrl({'id':id}), old=self.getProxyUrl(False), new=self.proxyUrl({'path':'a b'}))
    def proxy(self,params): return [206,'application/octet-stream',bytes([0,255,128]),{'Content-Range':'bytes 0-2/3'}]
'''
        base = "http://127.0.0.1:9999/opaque-token/proxy?do=py&siteKey=opaque"
        host = source(code, proxy_url=base)
        result = host.invoke("play", ["", "a&b", []])
        check("proxy_url_owned_parameters", result["url"] == base + "&id=a%26b")
        check("legacy_false_stays_loopback", result["old"] == base)
        check("new_proxy_encoding", result["new"] == base + "&path=a+b")
        reply = host.invoke("proxy", [{"range": "bytes=0-2"}])
        check("proxy_entry_not_hidden_by_base", reply == [206, "application/octet-stream", "AP+A", {"Content-Range": "bytes 0-2/3"}, 1])
        host.close()
    elif case == "limits":
        for label, entry, files in (
            ("traversal", "main.py", {"main.py": b"", "../bad": b""}),
            ("backslash", "main.py", {"main.py": b"", "a\\b": b""}),
            ("absolute", "main.py", {"main.py": b"", "/bad": b""}),
            ("case_alias", "main.py", {"main.py": b"", "MAIN.py": b""}),
            ("unicode_alias", "main.py", {"main.py": b"", "\u00e9": b"", "e\u0301": b""}),
            ("directory_file", "main.py", {"main.py": b"", "data": b"", "data/x": b""}),
            ("module_directory", "main.py", {"main.py": b"", "main/__init__.py": b""}),
            ("count", "main.py", {"main.py": b"", **{str(i): b"" for i in range(256)}}),
            ("file_size", "main.py", {"main.py": b"x" * (2*1024*1024+1)}),
            ("package_size", "main.py", {"main.py": b"x", **{str(i): b"x" * (2*1024*1024) for i in range(3)}}),
            ("missing_entry", "other.py", {"main.py": b""}),
        ):
            rejects("package_reject_" + label, lambda: validate_package(entry, files), SourceContractError)
        for label, files in (("reserved_module", {"main.py": b"", "json/owned.txt": b""}),
                             ("native_module", {"main.py": b"", "lib.so": b""})):
            rejects(label, lambda: NativePythonSource("main.py", files, bridge=no_network))
        check("package_exact_6mib", len(validate_package("main.py", {"main.py": b"x"*(2*1024*1024), "a": b"x"*(2*1024*1024), "b": b"x"*(2*1024*1024)})[1]) == 3)
        for label, value in (
            ("emoji_header", [200,"text/plain","x",{"x":"😀"}]),
            ("header_injection", [200,"text/plain","x",{"x":"a\r\nb"}]),
            ("duplicate_header", [200,"text/plain","x",{"X":"a","x":"b"}]),
            ("status_bool", [True,"text/plain","x"]),
            ("flag_bool", [200,"text/plain",b"x",{},True]),
            ("invalid_bytes", [200,"text/plain",[True]]),
            ("invalid_base64", [200,"text/plain","!!!",{},1]),
            ("oversize_bytes", [200,"text/plain",b"x"*(MAX_BODY+1)]),
        ):
            rejects("proxy_reject_" + label, lambda: normalize_proxy(value), SourceContractError)
        check("proxy_latin1_header", normalize_proxy([200,"text/plain","x",{"x":"é"}])[3] == {"x":"é"})
        check("proxy_text", normalize_proxy([200,"text/plain","中文"]) == [200,"text/plain","中文",{},0])
        check("proxy_integer_bytes", normalize_proxy([200,"application/octet-stream",[0,255,128]])[2:] == ["AP+A",{},1])
        check("proxy_data_base64", normalize_proxy([200,"text/plain","data:text/plain;base64,eA==",{},1])[2] == "eA==")
    elif case == "proxy_limit":
        host = source("from base.spider import Spider as Base\nclass Spider(Base):\n def localProxy(self,p): return [200,'application/octet-stream',b'x'*(6*1024*1024),{'x':'é'}]\n")
        reply = host.invoke("proxy", [{}])
        check("proxy_exact_6mib_real_invoke", len(base64.b64decode(reply[2])) == MAX_BODY and reply[3] == {"x":"é"})
        host.close()
    elif case == "release":
        previous = requests.Session
        files = {"pkg/__init__.py": b"", "pkg/main.py": b"import requests,importlib.resources\nfrom base.spider import Spider as Base\nresource=importlib.resources.files('pkg').joinpath('text.txt')\nstream=resource.open('rb')\nclass Spider(Base):\n def homeContent(self,f): return {}\n", "pkg/text.txt": b"owned"}
        host = NativePythonSource("pkg/main.py", files, bridge=no_network)
        host.invoke("home", [False]); module = sys.modules["pkg.main"]
        resource, stream, loader = module.resource, module.stream, module.__loader__
        host.close(); host.close()
        check("release_module_names_removed", not any(name in sys.modules for name in ("pkg", "pkg.main", "base.spider")))
        check("release_requests_restored", requests.Session is previous)
        rejects("released_resource_rejected", resource.read_bytes, SourceContractError)
        rejects("released_stream_closed", stream.read, ValueError)
        rejects("released_loader_rejected", lambda: loader.get_data(module.__file__), SourceContractError)
        rejects("one_source_per_interpreter", lambda: source(""), SourceContractError)
    elif case in ("isolation_a", "isolation_b"):
        value = case[-1]
        host = source("from base.spider import Spider as Base\nclass Spider(Base):\n def homeContent(self,f): return {'value':'" + value + "'}\n")
        check("dedicated_process_owned_state", host.invoke("home", [False]) == {"value": value})
        check("source_module_origin", sys.modules["main"].__file__.startswith(host.origin))
        host.close()
    return {"case": case, "passed": True, "checks": checks}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-dir", type=Path)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--case", choices=CASES, help=argparse.SUPPRESS)
    parser.add_argument("--packages", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.case:
        print(json.dumps(child(args.case, args.packages.resolve()), ensure_ascii=True))
        return
    if not args.cache_dir or not args.output_dir:
        parser.error("--cache-dir and --output-dir are required")
    lockfile = ROOT / "scripts/ios_cpython/pure-dependencies.lock.json"
    lock = json.loads(lockfile.read_text(encoding="utf-8"))
    for package in lock["packages"]:
        path = args.cache_dir / "wheels" / package["file"]
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != package["sha256"]:
            raise ValueError("Missing/mismatched locked wheel: " + package["file"])
    args.output_dir.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="native-source-", dir=args.output_dir.resolve()))
    packages = output / "packages"; packages.mkdir()
    spec = importlib.util.spec_from_file_location("owned_probe", ROOT / "scripts/ios_cpython/run_cpython_probe.py")
    helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
    inputs = helper.stage_wheels(packages, args.cache_dir.resolve())
    results = []
    for case in CASES:
        run = subprocess.run([sys.executable, "-I", "-B", str(Path(__file__).resolve()), "--case", case,
                              "--packages", str(packages)], capture_output=True, text=True, encoding="utf-8", timeout=35)
        (output / (case + ".log")).write_text(run.stdout + run.stderr, encoding="utf-8")
        if run.returncode:
            raise RuntimeError("Candidate host check failed: " + case + "\n" + run.stderr[-6000:])
        record = json.loads(run.stdout)
        if not record["passed"] or not record["checks"] or not all(item["passed"] for item in record["checks"]):
            raise AssertionError("Incomplete child result")
        results.append(record)
    records = [dict(name=case["case"] + "/" + item["name"], passed=item["passed"])
               for case in results for item in case["checks"]]
    if len({item["name"] for item in records}) != len(records):
        raise AssertionError("Nonunique case/check")
    owned = [HOST / "host.py", HOST / "base/spider.py", Path(__file__).resolve(),
             TRANSPORT / "requests_adapter.py", lockfile]
    report = dict(version=1, passed=True, scope="candidate-host-local-subprocess-only",
                  python=sys.version, cases=len(results), checks=records, dependencies=inputs,
                  sourceHashes={str(path.relative_to(ROOT)).replace('\\','/'): hashlib.sha256(path.read_bytes()).hexdigest() for path in owned})
    (output / "result.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(dict(passed=True, cases=len(results), checks=len(records), report=str(output / "result.json"))))


if __name__ == "__main__":
    main()
