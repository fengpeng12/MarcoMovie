"""Candidate shared Python loader, not enabled for production execution.

Android's automatic assets packaging may include these files; presence alone
does not enable native CPython source dispatch.

One source lifetime per dedicated interpreter. This is not a filesystem, native
extension or security sandbox, and deadline checks cannot interrupt arbitrary C.
"""
from __future__ import annotations

import importlib
import importlib.abc
import importlib.resources.abc
import importlib.util
import inspect
import io
import json
from pathlib import Path
import re
import sys
import types
import unicodedata
from urllib.parse import quote, unquote, urlsplit, urlencode
import uuid
import weakref
import base64

import requests
import requests.api
import requests.sessions
import requests.adapters
from requests_adapter import BridgeSession, CallContext, UnsupportedFeature, MAX_BODY

_INTERPRETER_USED = False
_TOKEN = r"[!#$%&'*+.^_`|~0-9A-Za-z-]+"
_MIME = re.compile(r"^" + _TOKEN + "/" + _TOKEN + r"(?: *;[^\r\n]*)?$")


class SourceContractError(ValueError):
    pass


def _path(value):
    if not isinstance(value, str) or not value or len(value) > 1024:
        raise SourceContractError("Invalid package path")
    value = unicodedata.normalize("NFC", value)
    if (value.startswith("/") or "\\" in value or ":" in value
            or any(ord(c) < 32 or ord(c) == 127 for c in value)
            or any(part in ("", ".", "..") for part in value.split("/"))):
        raise SourceContractError("Package path escapes virtual root")
    return value


def validate_package(entry, files):
    if not isinstance(files, dict) or not 1 <= len(files) <= 256:
        raise SourceContractError("Package requires 1..256 files")
    normalized, folded, total = {}, set(), 0
    for name, content in files.items():
        name = _path(name)
        if name.casefold() in folded:
            raise SourceContractError("Duplicate normalized package path")
        if not isinstance(content, bytes) or len(content) > 2 * 1024 * 1024:
            raise SourceContractError("Package files must be bytes and at most 2 MiB")
        total += len(content)
        if total > MAX_BODY:
            raise SourceContractError("Package exceeds 6 MiB")
        folded.add(name.casefold())
        normalized[name] = content
    for name in normalized:
        parts = name.split("/")
        if any("/".join(parts[:i]).casefold() in folded for i in range(1, len(parts))):
            raise SourceContractError("Package file conflicts with directory")
        if name.endswith(".py") and not name.endswith("/__init__.py"):
            module = name[:-3].casefold() + "/"
            if any(other.startswith(module) for other in folded):
                raise SourceContractError("Package module conflicts with directory")
    entry = _path(entry)
    if entry not in normalized or not entry.endswith(".py"):
        raise SourceContractError("Python package entry is missing")
    return entry, normalized


class _MemoryPath(importlib.resources.abc.Traversable):
    def __init__(self, source, path):
        self.source, self.path = source, path

    @property
    def name(self):
        return self.path.rsplit("/", 1)[-1]

    def is_file(self):
        self.source._ensure_open()
        return self.path in self.source.files

    def is_dir(self):
        self.source._ensure_open()
        return not self.path or any(p.startswith(self.path + "/") for p in self.source.files)

    def iterdir(self):
        self.source._ensure_open()
        prefix = self.path + "/" if self.path else ""
        if not self.is_dir():
            raise NotADirectoryError(self.path)
        names = sorted({p[len(prefix):].split("/", 1)[0] for p in self.source.files if p.startswith(prefix)})
        return iter(_MemoryPath(self.source, prefix + name) for name in names)

    def joinpath(self, *descendants):
        self.source._ensure_open()
        parts = [self.path] if self.path else []
        for child in descendants:
            parts.append(_path(child))
        return _MemoryPath(self.source, "/".join(parts))

    def open(self, mode="r", *args, **kwargs):
        self.source._ensure_open()
        if mode not in ("r", "rb"):
            raise UnsupportedFeature("Package resources are read-only")
        if not self.is_file():
            raise FileNotFoundError(self.path)
        raw = io.BytesIO(self.source.files[self.path])
        self.source._resource_streams.add(raw)
        if mode == "rb":
            if args or kwargs:
                raise ValueError("Binary resources do not accept text options")
            return raw
        return io.TextIOWrapper(raw, *args, **kwargs)


class _Resources(importlib.resources.abc.TraversableResources):
    def __init__(self, source, directory):
        self.source, self.directory = source, directory

    def files(self):
        self.source._ensure_open()
        return _MemoryPath(self.source, self.directory)


class _MemoryLoader(importlib.abc.SourceLoader):
    def __init__(self, source, path, directory, package):
        self.source, self.path, self.directory, self.package = source, path, directory, package

    def get_filename(self, fullname):
        self.source._ensure_open()
        return self.source.origin + quote(self.path or self.directory + "/__init__.py")

    def get_data(self, path):
        self.source._ensure_open()
        # pkgutil joins __file__ with the platform separator, including Windows.
        if not isinstance(path, str) or not path.startswith(self.source.origin):
            raise SourceContractError("Resource address is outside this source")
        relative = _path(unquote(path[len(self.source.origin):].replace("\\", "/")))
        try:
            return self.source.files[relative]
        except KeyError as error:
            raise FileNotFoundError(relative) from error

    def get_code(self, fullname):
        self.source._ensure_open()
        return compile(self.source.files[self.path] if self.path else b"", self.get_filename(fullname), "exec", dont_inherit=True)

    def is_package(self, fullname):
        return self.package

    def exec_module(self, module):
        self.source._loaded[module.__name__] = module
        super().exec_module(module)

    def get_resource_reader(self, fullname):
        return _Resources(self.source, self.directory) if self.package else None


class _Finder(importlib.abc.MetaPathFinder):
    def __init__(self, source):
        self.source = source

    def find_spec(self, fullname, path=None, target=None):
        source = self.source
        source._ensure_open()
        name = fullname
        if source.entry == "__init__.py" and (name == "_movie_source" or name.startswith("_movie_source.")):
            name = name[len("_movie_source"):].lstrip(".")
        relative = name.replace(".", "/")
        package_path = relative + "/__init__.py" if relative else "__init__.py"
        if package_path in source.files:
            file, directory, package = package_path, relative, True
        elif relative + ".py" in source.files:
            file, directory, package = relative + ".py", relative.rpartition("/")[0], False
        elif relative and any(p.startswith(relative + "/") for p in source.files):
            file, directory, package = None, relative, True
        else:
            return None
        loader = _MemoryLoader(source, file, directory, package)
        spec = importlib.util.spec_from_loader(fullname, loader, is_package=package)
        if package:
            spec.submodule_search_locations = [source.origin + quote(directory)]
        return spec


class _OperationContext(CallContext):
    def __init__(self, budget, cancellation, operation_id):
        super().__init__(budget, call_id=operation_id)
        self.external = cancellation

    @property
    def cancelled(self):
        return super().cancelled or self.external is not None and bool(self.external())


class NativePythonSource:
    """Candidate host: exactly one instance lifetime in a dedicated interpreter."""
    def __init__(self, entry, files, *, bridge, extension="", raw_extension=None, proxy_url=None):
        global _INTERPRETER_USED
        if _INTERPRETER_USED:
            raise SourceContractError("Each native source requires a fresh dedicated interpreter")
        self.entry, self.files = validate_package(entry, files)
        if not callable(bridge) or raw_extension is not None and not isinstance(raw_extension, str):
            raise SourceContractError("A real bridge and valid raw extension are required")
        self.ext = raw_extension if raw_extension is not None else extension if isinstance(extension, str) else json.dumps(extension, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
        if len(self.ext.encode("utf-8")) > 64 * 1024:
            raise SourceContractError("Source extension exceeds limit")
        self._proxy = self._validate_proxy(proxy_url)
        reserved = set(sys.stdlib_module_names) | {"base", "requests", "urllib3", "requests_adapter", "host", "_movie_source"}
        for path in self.files:
            root = path.split("/", 1)[0]
            root = root[:-3] if root.endswith(".py") else root
            if root in reserved or root in sys.modules:
                raise SourceContractError("Package cannot shadow an existing host module")
            if path.endswith(".py"):
                names = path[:-3].split("/")
                if not all(part.isidentifier() for part in names):
                    raise SourceContractError("Python module path must contain valid identifiers")
                if names[0] in reserved or names[0] in sys.modules:
                    raise SourceContractError("Package cannot shadow an existing host module")
            if path.lower().endswith((".so", ".dylib", ".dll", ".pyd", ".pth")):
                raise UnsupportedFeature("Package native extensions and path hooks are unsupported")
        if "base" in sys.modules or "base.spider" in sys.modules:
            raise SourceContractError("Host base module namespace is occupied")
        _INTERPRETER_USED = True
        self.origin = "pkg://" + uuid.uuid4().hex + "/"
        self.bridge = bridge
        self._closed = False
        self._failed = False
        self._state = "new"
        self._context = None
        self._sessions = weakref.WeakSet()
        self._resource_streams = weakref.WeakSet()
        self._loaded = {}
        self._patches = []
        self._finder = _Finder(self)
        self._spider = None
        self._requests = 0

    @staticmethod
    def _validate_proxy(value):
        if value is None:
            return None
        if not isinstance(value, str) or len(value) > 8192:
            raise SourceContractError("Invalid local proxy address")
        url = urlsplit(value)
        from urllib.parse import parse_qsl
        query = parse_qsl(url.query, keep_blank_values=True)
        if (url.scheme != "http" or url.hostname != "127.0.0.1" or not url.port
                or url.username is not None or url.password is not None or url.fragment
                or not url.path.startswith("/") or any(p in (".", "..") for p in url.path.split("/"))
                or len({k.lower() for k, _ in query}) != len(query)
                or dict(query).get("do") != "py" or not dict(query).get("siteKey")):
            raise SourceContractError("Only a source-owned loopback Python proxy is accepted")
        return value

    def _ensure_open(self):
        if self._closed:
            raise SourceContractError("Native Python source is closed")

    def _current(self):
        self._ensure_open()
        if self._context is None:
            raise SourceContractError("Source networking requires an active operation")
        self._context.check()
        return self._context

    def _network(self, envelope, context):
        if self._current() is not context:
            raise SourceContractError("HTTP request belongs to another operation")
        self._requests += 1
        if self._requests > 32:
            raise SourceContractError("Source operation exceeds 32 HTTP hops")
        return self.bridge(envelope, context)

    def _install(self):
        owner = self

        class ManagedSession(BridgeSession):
            def __init__(self):
                owner._current()
                if len(owner._sessions) >= 32:
                    raise SourceContractError("Too many retained HTTP sessions")
                super().__init__(owner._network)
                owner._sessions.add(self)

            def send(self, request, **kwargs):
                with self.call(owner._current()):
                    return super().send(request, **kwargs)

            def close(self):
                super().close()
                owner._sessions.discard(self)

        class UnsupportedAdapter(requests.adapters.BaseAdapter):
            # requests.Session.__init__ creates these temporary default
            # adapters; BridgeSession immediately replaces them with the real
            # bridge. Even a direct import of the sessions alias cannot send.
            def __init__(self, *args, **kwargs):
                pass

            def send(self, *args, **kwargs):
                raise UnsupportedFeature("Custom socket HTTPAdapter is not available in the native source profile")

            def close(self):
                pass

        for module, key, value in ((requests, "Session", ManagedSession),
                                   (requests.sessions, "Session", ManagedSession),
                                   (requests.sessions, "HTTPAdapter", UnsupportedAdapter),
                                   (requests.adapters, "HTTPAdapter", UnsupportedAdapter)):
            self._patches.append((module, key, getattr(module, key)))
            setattr(module, key, value)
        base = types.ModuleType("base")
        base.__path__ = ["marco://python-native/base"]
        base.__package__ = "base"
        spider = types.ModuleType("base.spider")
        spider.__file__ = "marco://python-native/base/spider.py"
        spider.__package__ = "base"
        spider._HOST = self
        code = (Path(__file__).parent / "base" / "spider.py").read_bytes()
        exec(compile(code, spider.__file__, "exec", dont_inherit=True), spider.__dict__)
        base.spider = spider
        sys.modules["base"], sys.modules["base.spider"] = base, spider
        self._loaded.update({"base": base, "base.spider": spider})
        sys.meta_path.insert(0, self._finder)

    def _initialize(self):
        if self._state != "new":
            if self._state != "ready":
                raise SourceContractError("Source initialization failed and cannot be replayed")
            return
        self._state = "loading"
        self._install()
        if self.entry == "__init__.py":
            name = "_movie_source"
        else:
            name = self.entry[:-3].replace("/", ".")
            if name.endswith(".__init__"):
                name = name[:-len(".__init__")]
        module = importlib.import_module(name)
        cls = getattr(module, "Spider", None)
        if not inspect.isclass(cls):
            raise SourceContractError("Python source must export a Spider class")
        self._spider = cls()
        self._call("init", [self.ext])
        self._state = "ready"

    def _call(self, name, args):
        method = getattr(self._spider, name, None)
        if not callable(method):
            raise SourceContractError("Python Spider is missing " + name)
        result = method(*args)
        if inspect.isawaitable(result):
            if inspect.iscoroutine(result):
                result.close()
            raise UnsupportedFeature("Coroutine Spider methods are not supported by this synchronous profile")
        return result

    def invoke(self, method, args, *, budget=12, cancellation=None, operation_id=None):
        self._ensure_open()
        if self._failed or self._state == "failed":
            raise SourceContractError("Failed source cannot be invoked or initialized again")
        if self._context is not None:
            raise SourceContractError("Source operations must be serialized")
        if not isinstance(args, list) or cancellation is not None and not callable(cancellation):
            raise SourceContractError("Invalid operation arguments")
        if operation_id is not None and (not isinstance(operation_id, str)
                or re.fullmatch(r"[0-9a-f]{32}", operation_id) is None):
            raise SourceContractError("Invalid native operation identity")
        counts = {"home": 1, "homeVod": 0, "category": 4, "search": 3, "detail": 1, "play": 3, "proxy": 1, "liveContent": 1}
        if method not in counts or len(args) != counts[method]:
            raise SourceContractError("Invalid Spider operation or arity")
        self._context = _OperationContext(budget, cancellation, operation_id)
        self._requests = 0
        try:
            self._current()
            self._initialize()
            self._current()
            if method == "search":
                fn = getattr(self._spider, "searchContent", None)
                if not callable(fn):
                    raise SourceContractError("Python Spider is missing searchContent")
                signature = inspect.signature(fn)
                selected = [args[0], args[1], str(args[2])]
                try:
                    signature.bind(*selected)
                except TypeError:
                    selected = args[:2]
                    signature.bind(*selected)
                result = self._call("searchContent", selected)
            elif method == "proxy":
                name = "localProxy" if callable(getattr(self._spider, "localProxy", None)) else "proxy"
                result = normalize_proxy(self._call(name, args))
            else:
                names = {"home": "homeContent", "homeVod": "homeVideoContent", "category": "categoryContent", "detail": "detailContent", "play": "playerContent", "liveContent": "liveContent"}
                selected = [args[0], str(args[1]), args[2], args[3]] if method == "category" else [args[0] if isinstance(args[0], list) else [args[0]]] if method == "detail" else args
                result = self._call(names[method], selected)
            if method != "proxy" and isinstance(result, str):
                try:
                    result = json.loads(result)
                except json.JSONDecodeError:
                    if method != "liveContent":
                        raise
            wire = json.dumps(result, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
            # Base64 of exactly 6 MiB occupies 8 MiB; reserve space for the
            # separately bounded headers and JSON escaping. Text also has this
            # wire cap (in addition to its decoded 6 MiB cap).
            if len(wire.encode("utf-8")) > (8 * 1024 * 1024 + 128 * 1024 if method == "proxy" else MAX_BODY):
                raise SourceContractError("Spider response exceeds limit")
            self._current()
            return result
        except BaseException:
            self._failed = True
            if self._state != "ready":
                self._state = "failed"
            raise
        finally:
            self._context = None

    def proxy_url(self, params=None, local=True, *, legacy=False):
        self._current()
        if self._proxy is None:
            raise UnsupportedFeature("Source-owned local proxy bridge is unavailable")
        if legacy and isinstance(params, bool):
            local, params = params, None
        if type(local) is not bool:
            raise TypeError("Proxy local flag must be a boolean")
        if legacy:
            params = {} if params is None else dict(params)
        elif params is None:
            params = {}
        if not isinstance(params, dict):
            raise TypeError("Proxy parameters must be a dict")
        for key, value in params.items():
            if not isinstance(key, str) or key.lower() in ("do", "sitekey"):
                raise ValueError("Invalid or reserved proxy parameter")
            if not isinstance(value, str) and not (legacy and type(value) in (int, bool)):
                raise TypeError("Proxy parameter values must be strings")
        # Compatibility local=False never changes the loopback-only destination.
        value = self._proxy + ("&" + urlencode(params) if params else "")
        if len(value) > 8192:
            raise ValueError("Proxy URL exceeds limit")
        return value

    def close(self):
        if self._closed:
            return
        self._closed = True
        if self._context is not None:
            self._context.cancel()
        for session in list(self._sessions):
            BridgeSession.close(session)
        self._sessions.clear()
        for stream in list(self._resource_streams):
            stream.close()
        self._resource_streams.clear()
        if self._finder in sys.meta_path:
            sys.meta_path.remove(self._finder)
        for name, module in self._loaded.items():
            if sys.modules.get(name) is module:
                del sys.modules[name]
        for module, key, value in reversed(self._patches):
            setattr(module, key, value)
        self._loaded.clear()


def normalize_proxy(value):
    if not isinstance(value, (list, tuple)) or not 3 <= len(value) <= 5:
        raise SourceContractError("Proxy requires status, MIME, body, optional headers and Base64 flag")
    status, mime, body = value[:3]
    flag = value[4] if len(value) == 5 else 0
    if (type(status) is not int or not 200 <= status <= 599 or not isinstance(mime, str)
            or len(mime) > 256 or not _MIME.fullmatch(mime)
            or any(ord(c) < 32 or ord(c) > 126 for c in mime)
            or type(flag) is not int or flag not in (0, 1)):
        raise SourceContractError("Invalid proxy response metadata")
    headers = value[3] if len(value) > 3 and value[3] is not None else {}
    if not isinstance(headers, dict) or len(headers) > 64:
        raise SourceContractError("Invalid proxy response headers")
    seen, size = set(), 0
    for key, text in headers.items():
        if (not isinstance(key, str) or not re.fullmatch(_TOKEN, key) or key.lower() in seen
                or not isinstance(text, str) or re.search(r"[\x00-\x08\x0a-\x1f\x7f]", text)
                or any(ord(c) > 255 for c in text)):
            raise SourceContractError("Invalid proxy response header")
        seen.add(key.lower())
        size += len(key.encode("ascii")) + len(text.encode("latin-1"))
    if size > 16384:
        raise SourceContractError("Proxy response headers exceed limit")
    if isinstance(body, list):
        if len(body) > MAX_BODY or any(type(v) is not int or not 0 <= v <= 255 for v in body):
            raise SourceContractError("Invalid proxy bytes")
        body = bytes(body)
    if isinstance(body, (bytes, bytearray)):
        if len(body) > MAX_BODY:
            raise SourceContractError("Proxy body exceeds limit")
        return [status, mime, base64.b64encode(body).decode("ascii"), dict(headers), 1]
    if not isinstance(body, str):
        raise SourceContractError("Proxy body must be text or bytes")
    if flag:
        if len(body) > ((MAX_BODY + 2) // 3) * 4 + 1280:
            raise SourceContractError("Proxy Base64 exceeds limit")
        text = body
        if text.startswith("data:"):
            prefix, separator, text = text.partition(",")
            if not separator or len(prefix) > 256 or not re.fullmatch(r"data:[\x20-\x7e]*;base64", prefix):
                raise SourceContractError("Invalid proxy data URL")
        text = re.sub(r"[ \t\r\n]", "", text)
        try:
            decoded = base64.b64decode(text, validate=True)
        except (ValueError, TypeError) as error:
            raise SourceContractError("Invalid proxy Base64") from error
        if len(decoded) > MAX_BODY or base64.b64encode(decoded).decode() != text:
            raise SourceContractError("Non-canonical proxy Base64")
        body = text
    elif len(body.encode("utf-8")) > MAX_BODY:
        raise SourceContractError("Proxy text exceeds limit")
    return [status, mime, body, dict(headers), flag]
