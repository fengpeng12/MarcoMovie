// The same Python Spider protocol runs over the device-local JS engine on each
// host. A suspended HTTP request becomes a Promise only on asynchronous hosts.
function createPythonSpider(source, files = {}, readSibling, packageData) {
  // Capture the host-owned route before importing user code. The local=False
  // compatibility argument never changes this app's loopback-only boundary.
  const suppliedProxyBase = typeof globalThis.__movieProxyBase === 'string' ? globalThis.__movieProxyBase : '';
  const proxyMatch = /^http:\/\/127\.0\.0\.1:([1-9]\d{0,4})\/[^\s?#]*\?[^\s#]*$/.exec(suppliedProxyBase);
  const proxyQuery = suppliedProxyBase.substring(suppliedProxyBase.indexOf('?') + 1);
  const proxyBase = proxyMatch && Number(proxyMatch[1]) <= 65535 &&
    /(?:^|&)do=py(?:&|$)/.test(proxyQuery) && /(?:^|&)siteKey=[^&]+(?:&|$)/.test(proxyQuery)
    ? suppliedProxyBase : '';
  const baseSpider = [
    "import requests",
    "from urllib.parse import urlencode",
    "_movie_proxy_base = " + JSON.stringify(proxyBase),
    "class Spider:",
    "    def init(self, extend=''): pass",
    "    def fetch(self, url, **kwargs): return requests.get(url, **kwargs)",
    "    def post(self, url, **kwargs): return requests.post(url, **kwargs)",
    "    def _movieProxyUrl(self, params):",
    "        if not _movie_proxy_base: raise NotImplementedError('Python local proxy bridge is unavailable')",
    "        if 'do' in params or 'siteKey' in params: raise ValueError('Reserved proxy parameter')",
    "        return _movie_proxy_base + ('&' + urlencode(params) if params else '')",
    "    def getProxyUrl(self, params=None, local=True):",
    "        if isinstance(params, bool): local, params = params, None",
    "        params = {} if params is None else dict(params)",
    "        return self._movieProxyUrl(params)",
    "    def proxyUrl(self, params=None, local=True):",
    "        params = {} if params is None else params",
    "        if not isinstance(params, dict) or any(not isinstance(k, str) or not isinstance(v, str) for k, v in params.items()): raise TypeError('Proxy parameters require a dict with string keys and values')",
    "        if not isinstance(local, bool): raise TypeError('Proxy local flag requires a boolean')",
    "        return self._movieProxyUrl(params)",
  ].join("\n");
  const requestsModule = [
    "import _movie_http, base64, json",
    "import json as _request_json",
    "from requests.exceptions import RequestException, HTTPError, ConnectionError, Timeout",
    "from requests import exceptions",
    "class CaseInsensitiveDict(dict):",
    "    def __init__(self, values):",
    "        for key, value in values.items(): self[key] = value",
    "    def __setitem__(self, key, value): dict.__setitem__(self, key.lower(), value)",
    "    def __getitem__(self, key): return dict.__getitem__(self, key.lower())",
    "    def __contains__(self, key): return dict.__contains__(self, key.lower())",
    "    def get(self, key, default=None): return dict.get(self, key.lower(), default)",
    "    def update(self, values=None, **kwargs):",
    "        for key, value in dict(values or {}, **kwargs).items(): self[key] = value",
    "    def __delitem__(self, key): dict.__delitem__(self, key.lower())",
    "class CookieConflictError(RuntimeError): pass",
    "class Cookie:",
    "    def __init__(self, entry): self._entry = entry",
    "    @property",
    "    def name(self): return self._entry['name']",
    "    @property",
    "    def value(self): return self._entry['value']",
    "    @value.setter",
    "    def value(self, value): self._entry['value'] = value",
    "    @property",
    "    def domain(self): return self._entry['domain']",
    "    @property",
    "    def path(self): return self._entry['path']",
    "    @property",
    "    def secure(self): return self._entry['secure']",
    "    @property",
    "    def expires(self):",
    "        value = self._entry.get('expires')",
    "        return None if value is None else int(value / 1000)",
    "    @property",
    "    def domain_specified(self): return bool(self.domain) and not self._entry.get('hostOnly', False)",
    "class RequestsCookieJar:",
    "    def __init__(self): self._entries = []",
    "    def __iter__(self): return iter([Cookie(entry) for entry in self._entries])",
    "    def set(self, name, value, domain='', path='/', secure=False, expires=None):",
    "        self._entries = _movie_http.cookie_set(self._entries, name, value, domain, path, secure, expires)",
    "        return value",
    "    def get(self, name, default=None, domain=None, path=None):",
    "        found = [c['value'] for c in self._entries if c['name'] == name and (domain is None or c['domain'] == domain.lstrip('.').lower()) and (path is None or c['path'] == path)]",
    "        if len(found) > 1: raise CookieConflictError('multiple cookies named ' + name)",
    "        return found[0] if found else default",
    "    def __getitem__(self, name):",
    "        value = self.get(name)",
    "        if value is None: raise KeyError(name)",
    "        return value",
    "    def __setitem__(self, name, value): self.set(name, value)",
    "    def __contains__(self, name): return any(c['name'] == name for c in self._entries)",
    "    def __len__(self): return len(self._entries)",
    "    def get_dict(self, domain=None, path=None):",
    "        return {c['name']:c['value'] for c in self._entries if (domain is None or c['domain'] == domain.lstrip('.').lower()) and (path is None or c['path'] == path)}",
    "    def keys(self): return [c['name'] for c in self._entries]",
    "    def values(self): return [c['value'] for c in self._entries]",
    "    def items(self): return [(c['name'], c['value']) for c in self._entries]",
    "    def update(self, values):",
    "        if isinstance(values, RequestsCookieJar): self._entries = _movie_http.cookie_merge(self._entries, values._entries)",
    "        else:",
    "            for key, value in dict(values).items(): self.set(key, value)",
    "    def clear(self, domain=None, path=None, name=None):",
    "        if name is not None and (domain is None or path is None): raise ValueError('domain and path required with name')",
    "        if path is not None and domain is None: raise ValueError('domain required with path')",
    "        self._entries = [c for c in self._entries if not ((domain is None or c['domain'] == domain.lstrip('.').lower()) and (path is None or c['path'] == path) and (name is None or c['name'] == name))]",
    "    def copy(self):",
    "        jar = RequestsCookieJar()",
    "        jar.update(self)",
    "        return jar",
    "class Response:",
    "    def __init__(self, r, url):",
    "        self.status_code = r['code']",
    "        self.url = r.get('url', url)",
    "        self.encoding = 'utf-8'",
    "        self.content = base64.b64decode(r['content'])",
    "        self.headers = CaseInsensitiveDict(r.get('headers', {}))",
    "        self.cookies = RequestsCookieJar()",
    "        self.cookies._entries = _movie_http.cookie_extract(self.headers.get('set-cookie', ''), self.url)",
    "        self.history = []",
    "        self.ok = self.status_code < 400",
    "    @property",
    "    def text(self): return self.content.decode(self.encoding, 'replace')",
    "    def json(self): return json.loads(self.text)",
    "    def close(self): pass",
    "    def __enter__(self): return self",
    "    def __exit__(self, *args): self.close()",
    "    def raise_for_status(self):",
    "        if self.status_code >= 400: raise HTTPError('HTTP ' + str(self.status_code))",
    "def request(method, url, headers=None, data=None, json=None, params=None, timeout=None, allow_redirects=True, cookies=None, auth=None, verify=True, **kwargs):",
    "    if kwargs: raise NotImplementedError('requests options unavailable: ' + ', '.join(kwargs.keys()))",
    "    if verify is not True: raise NotImplementedError('custom TLS verification is unavailable')",
    "    url = _movie_http.with_params(url, params)",
    "    headers = dict(headers or {})",
    "    if cookies:",
    "        jar = cookies if isinstance(cookies, RequestsCookieJar) else RequestsCookieJar()",
    "        if not isinstance(cookies, RequestsCookieJar): jar.update(cookies)",
    "        value = _movie_http.cookie_header(jar._entries, url)",
    "        if value and not any(k.lower() == 'cookie' for k in headers): headers['Cookie'] = value",
    "    if auth is not None:",
    "        if not isinstance(auth, (list, tuple)) or len(auth) != 2: raise NotImplementedError('only basic authentication pairs are available')",
    "        headers['Authorization'] = 'Basic ' + base64.b64encode((str(auth[0]) + ':' + str(auth[1])).encode('utf-8')).decode('ascii')",
    "    if json is not None:",
    "        if not any(k.lower() == 'content-type' for k in headers): headers['Content-Type'] = 'application/json'",
    "        data = _request_json.dumps(json, allow_nan=False)",
    "    elif isinstance(data, (dict, list, tuple)):",
    "        if not any(k.lower() == 'content-type' for k in headers): headers['Content-Type'] = 'application/x-www-form-urlencoded'",
    "        data = _movie_http.form_data(data)",
    "    options = {'method':method.upper(), 'headers':headers, 'data':data, 'redirect':1 if allow_redirects else 0, 'buffer':2}",
    "    if isinstance(data, bytes):",
    "        if len(data) > 6 * 1024 * 1024: raise ValueError('binary request body exceeds 6 MB')",
    "        options['bodyBase64'] = base64.b64encode(data).decode('ascii')",
    "        del options['data']",
    "    if timeout is not None:",
    "        if isinstance(timeout, (list, tuple)): timeout = max(timeout)",
    "        if timeout <= 0: raise ValueError('timeout must be positive')",
    "        options['timeout'] = int(timeout * 1000)",
    "    try:",
    "        result = _movie_http.request(url, options)",
    "    except Exception as error:",
    "        if 'timeout' in str(error).lower() or 'timed out' in str(error).lower() or '超时' in str(error): raise Timeout(str(error))",
    "        raise ConnectionError(str(error))",
    "    return Response(result, url)",
    "def get(url, params=None, **kwargs): return request('GET', url, params=params, **kwargs)",
    "def post(url, data=None, json=None, **kwargs): return request('POST', url, data=data, json=json, **kwargs)",
    "def put(url, data=None, **kwargs): return request('PUT', url, data=data, **kwargs)",
    "def patch(url, data=None, **kwargs): return request('PATCH', url, data=data, **kwargs)",
    "def delete(url, **kwargs): return request('DELETE', url, **kwargs)",
    "def head(url, **kwargs):",
    "    if 'allow_redirects' not in kwargs: kwargs['allow_redirects'] = False",
    "    return request('HEAD', url, **kwargs)",
    "class Session:",
    "    def __init__(self):",
    "        self.headers = CaseInsensitiveDict({})",
    "        self.cookies = RequestsCookieJar()",
    "        self.params = {}",
    "        self.auth = None",
    "        self.verify = True",
    "        self.max_redirects = 30",
    "    def request(self, method, url, headers=None, cookies=None, params=None, auth=None, allow_redirects=True, **kwargs):",
    "        from urllib.parse import urljoin, urlsplit",
    "        merged = CaseInsensitiveDict(self.headers)",
    "        for key, value in (headers or {}).items():",
    "            if value is None:",
    "                if key in merged: del merged[key]",
    "            else: merged[key] = value",
    "        query = dict(self.params)",
    "        if isinstance(params, dict): query.update(params)",
    "        elif params is not None:",
    "            if query: raise NotImplementedError('session params require dictionary merging')",
    "            query = params",
    "        url = _movie_http.with_params(url, query)",
    "        current_auth = self.auth if auth is None else auth",
    "        kwargs['verify'] = kwargs.get('verify', self.verify)",
    "        temporary = RequestsCookieJar()",
    "        if cookies is not None: temporary.update(cookies)",
    "        history = []",
    "        while True:",
    "            jar = self.cookies.copy()",
    "            jar.update(temporary)",
    "            response = request(method, url, headers=merged, cookies=jar, auth=current_auth, allow_redirects=False, **kwargs)",
    "            self.cookies.update(response.cookies)",
    "            response.history = list(history)",
    "            location = response.headers.get('location')",
    "            if not allow_redirects or response.status_code not in (301, 302, 303, 307, 308) or not location: return response",
    "            if len(history) >= min(self.max_redirects, 30): raise exceptions.TooManyRedirects('session redirect limit exceeded')",
    "            next_url = urljoin(response.url, location)",
    "            before, after = urlsplit(response.url), urlsplit(next_url)",
    "            if after.scheme not in ('http', 'https'): raise ValueError('redirect requires HTTP/HTTPS')",
    "            if (before.scheme, before.hostname, before.port) != (after.scheme, after.hostname, after.port):",
    "                current_auth = None",
    "                if 'authorization' in merged: del merged['authorization']",
    "            if 'cookie' in merged: del merged['cookie']",
    "            if response.status_code == 303 and method.upper() != 'HEAD' or response.status_code == 302 and method.upper() != 'HEAD' or response.status_code == 301 and method.upper() == 'POST':",
    "                method = 'GET'",
    "                kwargs.pop('data', None)",
    "                kwargs.pop('json', None)",
    "                for key in ['content-type', 'content-length', 'transfer-encoding']:",
    "                    if key in merged: del merged[key]",
    "            history.append(response)",
    "            url = next_url",
    "    def get(self, url, **kwargs): return self.request('GET', url, **kwargs)",
    "    def post(self, url, data=None, json=None, **kwargs): return self.request('POST', url, data=data, json=json, **kwargs)",
    "    def put(self, url, data=None, **kwargs): return self.request('PUT', url, data=data, **kwargs)",
    "    def patch(self, url, data=None, **kwargs): return self.request('PATCH', url, data=data, **kwargs)",
    "    def delete(self, url, **kwargs): return self.request('DELETE', url, **kwargs)",
    "    def head(self, url, **kwargs):",
    "        if 'allow_redirects' not in kwargs: kwargs['allow_redirects'] = False",
    "        return self.request('HEAD', url, **kwargs)",
    // The bridge owns its HTTP transport. Session has no separate pooled resource;
    // like requests, close does not clear cookies or permanently disable reuse.
    "    def close(self): pass",
    "    def __enter__(self): return self",
    "    def __exit__(self, *args): self.close()",
    "def session(): return Session()",
    "from requests import cookies",
  ].join("\n");
  const httpBridge = `var $builtinmodule = function() {
    function cookieUrl(value) {
      const m = /^(https?):\\/\\/([^/?#]+)([^?#]*)/i.exec(value);
      if (!m) throw new Sk.builtin.ValueError('cookies require an HTTP/HTTPS URL');
      const authority = m[2].split('@').pop();
      const host = (authority[0] === '[' ? authority.slice(1, authority.indexOf(']')) : authority.split(':')[0]).toLowerCase();
      return {host: host, path: m[3] || '/', secure: m[1].toLowerCase() === 'https'};
    }
    function matchesDomain(host, domain, hostOnly) {
      return host === domain || !hostOnly && !/^[0-9.]+$/.test(host) && host.indexOf(':') < 0 && host.endsWith('.' + domain);
    }
    function validCookie(name, value) {
      return typeof name === 'string' && name && name.length + String(value).length <= 4096 &&
        !/[\\s()<>@,;:\\\\"/\\[\\]?={}\\x00-\\x1f\\x7f]/.test(name) && !/[;\\r\\n\\x00-\\x1f\\x7f]/.test(value);
    }
    function key(cookie) { return cookie.name + '\\n' + cookie.domain + '\\n' + cookie.path; }
    function mergeCookies(current, incoming) {
      const now = Date.now(), result = current.filter(c => c.expires == null || c.expires > now);
      for (const cookie of incoming) {
        const existing = result.findIndex(c => key(c) === key(cookie));
        if (existing >= 0) result.splice(existing, 1);
        if (cookie.expires == null || cookie.expires > now) result.push(cookie);
      }
      if (result.length > 128) throw new Sk.builtin.ValueError('session cookie limit exceeded');
      return result;
    }
    function extractCookies(value, address) {
      if (!value) return [];
      const origin = cookieUrl(address), result = [];
      const lines = Array.isArray(value) ? value : String(value).split(/,\\s*(?=[^\\s=;,]+\\s*=)/);
      if (lines.length > 128 || String(value).length > 65536) throw new Sk.builtin.ValueError('response cookie limit exceeded');
      for (const line of lines) {
        if (line.length > 4096) continue;
        const parts = line.split(';'), first = parts.shift(), equal = first.indexOf('=');
        if (equal <= 0) continue;
        const name = first.slice(0, equal).trim(), value = first.slice(equal + 1).trim();
        if (!validCookie(name, value)) continue;
        const attrs = Object.create(null);
        for (const part of parts) {
          const index = part.indexOf('='), attr = (index < 0 ? part : part.slice(0, index)).trim().toLowerCase();
          attrs[attr] = index < 0 ? '' : part.slice(index + 1).trim();
        }
        const hostOnly = !Object.prototype.hasOwnProperty.call(attrs, 'domain');
        const domain = hostOnly ? origin.host : attrs.domain.replace(/^\\./, '').toLowerCase();
        if (!domain || domain.endsWith('.') || !matchesDomain(origin.host, domain, false) ||
            !hostOnly && domain.indexOf('.') < 0 && domain !== origin.host) continue;
        const path = attrs.path && attrs.path[0] === '/' ? attrs.path : origin.path.slice(0, origin.path.lastIndexOf('/')) || '/';
        const secure = Object.prototype.hasOwnProperty.call(attrs, 'secure');
        if (secure && !origin.secure || name.startsWith('__Secure-') && (!secure || !origin.secure) ||
            name.startsWith('__Host-') && (!secure || !origin.secure || !hostOnly || path !== '/')) continue;
        let expires = null;
        if (attrs['max-age'] != null && /^-?\\d+$/.test(attrs['max-age'])) {
          const seconds = Number(attrs['max-age']);
          expires = seconds <= 0 ? 0 : Date.now() + Math.min(seconds, 2147483647) * 1000;
        } else if (attrs.expires) {
          const stamp = Date.parse(attrs.expires);
          if (Number.isFinite(stamp)) expires = stamp;
        }
        result.push({name: name, value: value, domain: domain, hostOnly: hostOnly, path: path, secure: secure, expires: expires});
      }
      return result;
    }
    function query(p) {
      if (typeof p === 'string') return p;
      const result = [];
      const pairs = Array.isArray(p) ? p : Object.keys(p).map(k => [k, p[k]]);
      const quote = v => {
        if (v instanceof Uint8Array) return Array.from(v, b => b === 32 ? '+' : /[A-Za-z0-9_.~-]/.test(String.fromCharCode(b)) ? String.fromCharCode(b) : '%' + b.toString(16).toUpperCase().padStart(2, '0')).join('');
        return encodeURIComponent(v === true ? 'True' : v === false ? 'False' : String(v)).replace(/%20/g, '+').replace(/[!'()*]/g, c => '%' + c.charCodeAt(0).toString(16).toUpperCase());
      };
      for (const pair of pairs) {
        if (!Array.isArray(pair) || pair.length !== 2) throw new Sk.builtin.ValueError('expected key/value pairs');
        const values = Array.isArray(pair[1]) ? pair[1] : [pair[1]];
        for (const value of values) if (value != null) result.push(quote(pair[0]) + '=' + quote(value));
      }
      return result.join('&');
    }
    return {
      cookie_extract: new Sk.builtin.func(function(headers, url) {
        return Sk.ffi.remapToPy(extractCookies(Sk.ffi.remapToJs(headers), Sk.ffi.remapToJs(url)));
      }),
      cookie_merge: new Sk.builtin.func(function(current, incoming) {
        return Sk.ffi.remapToPy(mergeCookies(Sk.ffi.remapToJs(current), Sk.ffi.remapToJs(incoming)));
      }),
      cookie_set: new Sk.builtin.func(function(entries, name, value, domain, path, secure, expires) {
        const n = Sk.ffi.remapToJs(name), v = Sk.ffi.remapToJs(value), d = String(Sk.ffi.remapToJs(domain)).replace(/^\\./, '').toLowerCase();
        const p = Sk.ffi.remapToJs(path), expiration = Sk.ffi.remapToJs(expires);
        if (!validCookie(n, v == null ? '' : String(v)) || typeof p !== 'string' || !p.startsWith('/') || /[\\s;\\r\\n]/.test(d)) throw new Sk.builtin.ValueError('invalid cookie');
        const incoming = {name:n, value:String(v), domain:d, hostOnly:false, path:p, secure:Sk.misceval.isTrue(secure), expires:v == null ? 0 : expiration == null ? null : expiration * 1000};
        return Sk.ffi.remapToPy(mergeCookies(Sk.ffi.remapToJs(entries), [incoming]));
      }),
      cookie_header: new Sk.builtin.func(function(entries, url) {
        const origin = cookieUrl(Sk.ffi.remapToJs(url)), now = Date.now();
        const source = Sk.ffi.remapToJs(entries);
        if (source.some(c => !validCookie(c.name, c.value))) throw new Sk.builtin.ValueError('invalid cookie');
        const allowed = source.filter(c => (c.expires == null || c.expires > now) &&
          (!c.domain || matchesDomain(origin.host, c.domain, c.hostOnly)) && (!c.secure || origin.secure) &&
          (origin.path === c.path || origin.path.startsWith(c.path) && (c.path.endsWith('/') || origin.path[c.path.length] === '/')));
        allowed.sort((a, b) => b.path.length - a.path.length);
        return new Sk.builtin.str(allowed.map(c => c.name + '=' + c.value).join('; '));
      }),
      with_params: new Sk.builtin.func(function(url, params) {
        const value = Sk.ffi.remapToJs(url), q = query(Sk.ffi.remapToJs(params) || {});
        const hash = value.indexOf('#'), base = hash < 0 ? value : value.substring(0, hash), fragment = hash < 0 ? '' : value.substring(hash);
        return new Sk.builtin.str(base + (q ? (base.indexOf('?') < 0 ? '?' : /[?&]$/.test(base) ? '' : '&') + q : '') + fragment);
      }),
      form_data: new Sk.builtin.func(function(data) {
        return new Sk.builtin.str(query(Sk.ffi.remapToJs(data)));
      }),
      request: new Sk.builtin.func(function(url, opts) {
      const r = req(Sk.ffi.remapToJs(url), Sk.ffi.remapToJs(opts));
      if (r && typeof r.then === "function") {
        return Sk.misceval.promiseToSuspension(r.then(v => Sk.ffi.remapToPy(v)));
      }
      return Sk.ffi.remapToPy(r);
    })};
  };`;
  const library = Object.assign(Object.create(null), Sk.builtinFiles.files);
  if (typeof installPythonHtml === 'function') installPythonHtml(library);
  if (typeof installPythonRegex === 'function') installPythonRegex(library);
  // Skulpt ships placeholder base64/urllib modules. Implement the byte and URL
  // primitives locally; no platform process or external service is involved.
  library["src/lib/_movie_codec.js"] = `var $builtinmodule = function() {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    function bytes(value, textAllowed) {
      if (value instanceof Sk.builtin.bytes) return value.v;
      if (textAllowed && value instanceof Sk.builtin.str) {
        if (/[^\\x00-\\x7f]/.test(value.v)) throw new Sk.builtin.ValueError('base64 input must be ASCII');
        return Uint8Array.from(value.v, c => c.charCodeAt(0));
      }
      throw new Sk.builtin.TypeError('a bytes-like object is required');
    }
    function alt(value) {
      if (value === undefined || value === Sk.builtin.none.none$) return null;
      const pair = bytes(value, true);
      if (pair.length !== 2) throw new Sk.builtin.ValueError('altchars must contain two bytes');
      return Array.from(pair, x => String.fromCharCode(x));
    }
    function encode(value, alternative) {
      const input = bytes(value, false), pair = alt(alternative), chars = pair ? alphabet.substring(0, 62) + pair.join('') : alphabet;
      let result = '';
      for (let i = 0; i < input.length; i += 3) {
        const bits = (input[i] << 16) | ((input[i + 1] || 0) << 8) | (input[i + 2] || 0);
        result += chars[(bits >>> 18) & 63] + chars[(bits >>> 12) & 63] + (i + 1 < input.length ? chars[(bits >>> 6) & 63] : '=') + (i + 2 < input.length ? chars[bits & 63] : '=');
      }
      return new Sk.builtin.bytes(Uint8Array.from(result, x => x.charCodeAt(0)));
    }
    function decode(value, alternative, validate) {
      const pair = alt(alternative);
      const input = bytes(value, true);
      let text = '';
      for (let i = 0; i < input.length; i += 8192) text += String.fromCharCode.apply(null, input.subarray(i, i + 8192));
      if (pair) text = Array.from(text, c => c === pair[0] ? '+' : c === pair[1] ? '/' : c).join('');
      const strict = validate !== undefined && Sk.misceval.isTrue(validate);
      if (strict && /[^A-Za-z0-9+/=]/.test(text)) throw new Sk.builtin.ValueError('Only base64 data is allowed');
      text = text.replace(/[^A-Za-z0-9+/=]/g, '');
      if (!strict) text = text.replace(/=(?=.*[^=])/g, '');
      const end = text.indexOf('='), body = end < 0 ? text : text.substring(0, end), padding = end < 0 ? '' : text.substring(end);
      if (body.length % 4 === 1 || /[^=]/.test(padding) ||
          (body.length % 4 !== 0 && padding.length < 4 - body.length % 4) ||
          (strict && padding.length !== (4 - body.length % 4) % 4)) throw new Sk.builtin.ValueError('Incorrect padding');
      const output = new Uint8Array(Math.floor(body.length * 6 / 8)); let bits = 0, count = 0, position = 0;
      for (const c of body) {
        bits = (bits << 6) | alphabet.indexOf(c); count += 6;
        if (count >= 8) { count -= 8; output[position++] = (bits >>> count) & 255; }
      }
      return new Sk.builtin.bytes(output);
    }
    function quote(value, safe, plus) {
      const keep = Sk.ffi.remapToJs(safe);
      if (value instanceof Sk.builtin.bytes) {
        return new Sk.builtin.str(Array.from(value.v, b => /[A-Za-z0-9_.~-]/.test(String.fromCharCode(b)) || keep.indexOf(String.fromCharCode(b)) >= 0 ? String.fromCharCode(b) : '%' + b.toString(16).toUpperCase().padStart(2, '0')).join(''));
      }
      const text = Sk.ffi.remapToJs(value);
      let result = encodeURIComponent(text).replace(/[!'()*]/g, c => '%' + c.charCodeAt(0).toString(16).toUpperCase());
      for (const c of keep) if (/^[\\x00-\\x7f]$/.test(c)) result = result.split('%' + c.charCodeAt(0).toString(16).toUpperCase().padStart(2, '0')).join(c);
      return new Sk.builtin.str(Sk.misceval.isTrue(plus) ? result.replace(/%20/g, '+') : result);
    }
    return {
      b64encode: new Sk.builtin.func(encode), b64decode: new Sk.builtin.func(decode),
      quote: new Sk.builtin.func(quote),
      unquote: new Sk.builtin.func(function(value) {
        const rawBytes = value instanceof Sk.builtin.bytes;
        const text = rawBytes ? Array.from(value.v, b => String.fromCharCode(b)).join('') : Sk.ffi.remapToJs(value), output = [];
        for (let i = 0; i < text.length; i++) {
          if (text[i] === '%' && /^[0-9a-fA-F]{2}$/.test(text.substring(i + 1, i + 3))) { output.push(parseInt(text.substring(i + 1, i + 3), 16)); i += 2; }
          else if (rawBytes) output.push(text.charCodeAt(i));
          else {
            const code = text.codePointAt(i), encoded = encodeURIComponent(String.fromCodePoint(code));
            if (code > 65535) i++;
            for (let j = 0; j < encoded.length; j++) {
              if (encoded[j] === '%') { output.push(parseInt(encoded.substring(j + 1, j + 3), 16)); j += 2; }
              else output.push(encoded.charCodeAt(j));
            }
          }
        }
        return new Sk.builtin.bytes(output);
      }),
      split: new Sk.builtin.func(function(value) {
        const text = Sk.ffi.remapToJs(value), match = /^([a-zA-Z][a-zA-Z0-9+.-]*:)?(\\/\\/[^/?#]*)?([^?#]*)(\\?[^#]*)?(#.*)?$/.exec(text);
        return Sk.ffi.remapToPy([match[1] ? match[1].slice(0, -1).toLowerCase() : '', match[2] ? match[2].slice(2) : '', match[3], match[4] ? match[4].slice(1) : '', match[5] ? match[5].slice(1) : '']);
      }),
    };
  };`;
  library["src/lib/base64.py"] = [
    "import _movie_codec",
    "def b64encode(s, altchars=None): return _movie_codec.b64encode(s, altchars)",
    "def b64decode(s, altchars=None, validate=False): return _movie_codec.b64decode(s, altchars, validate)",
    "def standard_b64encode(s): return b64encode(s)",
    "def standard_b64decode(s): return b64decode(s)",
    "def urlsafe_b64encode(s): return b64encode(s, b'-_')",
    "def urlsafe_b64decode(s): return b64decode(s, b'-_')",
  ].join("\n");
  library["src/lib/urllib/parse.py"] = [
    "import _movie_codec",
    "def quote(string, safe='/', encoding='utf-8', errors='strict'):",
    "    if encoding.lower() not in ('utf-8', 'utf8'): raise NotImplementedError('URL encoding: ' + encoding)",
    "    return _movie_codec.quote(string, safe, False)",
    "def quote_plus(string, safe='', encoding='utf-8', errors='strict'):",
    "    return quote(string, safe, encoding, errors).replace('%20', '+').replace(' ', '+')",
    "def unquote(string, encoding='utf-8', errors='replace'): return _movie_codec.unquote(string).decode(encoding, errors)",
    "def unquote_to_bytes(string): return _movie_codec.unquote(string)",
    "def unquote_plus(string, encoding='utf-8', errors='replace'): return unquote(string.replace('+', ' '), encoding, errors)",
    "def urlencode(query, doseq=False, safe='', encoding='utf-8', errors='strict', quote_via=quote_plus):",
    "    pairs = query.items() if isinstance(query, dict) else query",
    "    parts = []",
    "    for key, value in pairs:",
    "        values = value if doseq and isinstance(value, (list, tuple)) else [value]",
    "        for item in values: parts.append(quote_via(str(key), safe, encoding, errors) + '=' + quote_via(str(item), safe, encoding, errors))",
    "    return '&'.join(parts)",
    "def parse_qsl(qs, keep_blank_values=False, strict_parsing=False, encoding='utf-8', errors='replace', max_num_fields=None, separator='&'):",
    "    fields = qs.split(separator) if qs else []",
    "    if max_num_fields is not None and len(fields) > max_num_fields: raise ValueError('Max number of fields exceeded')",
    "    pairs = []",
    "    for field in fields:",
    "        if '=' not in field:",
    "            if strict_parsing: raise ValueError('bad query field')",
    "            if not keep_blank_values: continue",
    "        pair = field.split('=', 1)",
    "        value = pair[1] if len(pair) > 1 else ''",
    "        if value or keep_blank_values: pairs.append((unquote_plus(pair[0], encoding, errors), unquote_plus(value, encoding, errors)))",
    "    return pairs",
    "def parse_qs(qs, **kwargs):",
    "    values = {}",
    "    for key, value in parse_qsl(qs, **kwargs): values.setdefault(key, []).append(value)",
    "    return values",
    "class SplitResult:",
    "    def __init__(self, parts): self.scheme, self.netloc, self.path, self.query, self.fragment = parts",
    "    def __iter__(self): return iter((self.scheme, self.netloc, self.path, self.query, self.fragment))",
    "    def __getitem__(self, index): return tuple(self)[index]",
    "    def geturl(self): return urlunsplit(self)",
    "    @property",
    "    def hostname(self):",
    "        host = self.netloc.rsplit('@', 1)[-1]",
    "        return (host[1:].split(']', 1)[0] if host.startswith('[') else host.split(':', 1)[0]).lower() if host else None",
    "    @property",
    "    def port(self):",
    "        host = self.netloc.rsplit('@', 1)[-1]",
    "        part = host.split(']', 1)[-1] if host.startswith('[') else host",
    "        if ':' not in part: return None",
    "        value = part.rsplit(':', 1)[-1]",
    "        if not value: return None",
    "        port = int(value)",
    "        if port < 0 or port > 65535: raise ValueError('Port out of range')",
    "        return port",
    "    @property",
    "    def username(self): return self.netloc.rsplit('@', 1)[0].split(':', 1)[0] if '@' in self.netloc else None",
    "    @property",
    "    def password(self):",
    "        user = self.netloc.rsplit('@', 1)[0] if '@' in self.netloc else ''",
    "        return user.split(':', 1)[1] if ':' in user else None",
    "def urlsplit(url, scheme='', allow_fragments=True):",
    "    parts = _movie_codec.split(url)",
    "    if not parts[0]: parts[0] = scheme",
    "    if not allow_fragments and parts[4]:",
    "        index = 3 if '?' in url.split('#', 1)[0] else 2",
    "        parts[index] += '#' + parts[4]",
    "        parts[4] = ''",
    "    return SplitResult(parts)",
    "def urlunsplit(parts):",
    "    scheme, netloc, path, query, fragment = parts",
    "    return (scheme + ':' if scheme else '') + ('//' + netloc if netloc or scheme in ('http', 'https', 'file') else '') + path + ('?' + query if query else '') + ('#' + fragment if fragment else '')",
    "class ParseResult(SplitResult):",
    "    def __init__(self, parts): self.scheme, self.netloc, self.path, self.params, self.query, self.fragment = parts",
    "    def __iter__(self): return iter((self.scheme, self.netloc, self.path, self.params, self.query, self.fragment))",
    "    def geturl(self): return urlunparse(self)",
    "def urlparse(url, scheme='', allow_fragments=True):",
    "    u = urlsplit(url, scheme, allow_fragments)",
    "    path, params = u.path, ''",
    "    if path.rfind(';') > path.rfind('/'): path, params = path.rsplit(';', 1)",
    "    return ParseResult((u.scheme, u.netloc, path, params, u.query, u.fragment))",
    "def urlunparse(parts):",
    "    scheme, netloc, path, params, query, fragment = parts",
    "    return urlunsplit((scheme, netloc, path + (';' + params if params else ''), query, fragment))",
    "def urljoin(base, url, allow_fragments=True):",
    "    if not base: return url",
    "    if not url: return base",
    "    b, u = urlsplit(base, allow_fragments=allow_fragments), urlsplit(url, allow_fragments=allow_fragments)",
    "    if u.scheme and u.scheme != b.scheme: return url",
    "    if b.scheme and b.scheme not in ('http', 'https', 'ftp', 'file', 'ws', 'wss'): return url",
    "    if u.netloc: return urlunsplit((u.scheme or b.scheme, u.netloc, u.path, u.query, u.fragment))",
    "    if not u.path: return urlunsplit((b.scheme, b.netloc, b.path, u.query or b.query, u.fragment))",
    "    path = u.path if u.path.startswith('/') else b.path.rsplit('/', 1)[0] + '/' + u.path if '/' in b.path else '/' + u.path if b.netloc else u.path",
    "    source_segments = path.split('/')",
    "    if not u.path.startswith('/'): source_segments = source_segments[:1] + [s for s in source_segments[1:-1] if s] + source_segments[-1:]",
    "    segments = []",
    "    for segment in source_segments:",
    "        if segment == '..':",
    "            if segments and segments[-1] != '': segments.pop()",
    "        elif segment != '.': segments.append(segment)",
    "    if source_segments[-1] in ('.','..'): segments.append('')",
    "    path = '/'.join(segments) or ('/' if b.netloc else '')",
    "    return urlunsplit((b.scheme, b.netloc, path, u.query, u.fragment))",
  ].join("\n");
  installPythonJson(library);
  installPythonIo(library);
  const localPackage = installPythonPackage(library, packageData);
  library["src/lib/base/__init__.py"] = "";
  library["src/lib/base/spider.py"] = baseSpider;
  library["src/lib/requests/__init__.py"] = requestsModule;
  library["src/lib/requests/cookies.py"] = "from requests import RequestsCookieJar, CookieConflictError\n";
  library["src/lib/requests/exceptions.py"] = [
    "class RequestException(Exception): pass",
    "class HTTPError(RequestException): pass",
    "class ConnectionError(RequestException): pass",
    "class Timeout(RequestException): pass",
    "class TooManyRedirects(RequestException): pass",
  ].join("\n");
  library["src/lib/_movie_http.js"] = httpBridge;
  const standardRoots = new Set(Object.keys(library).map(path =>
    /^src\/lib\/([^/.]+)(?:\.|\/)/.exec(path)?.[1]).filter(Boolean));
  for (const path of Object.keys(files)) {
    if (!['io', '_movie_io', '_movie_package'].includes(path.split(/[/.]/)[0]) &&
        /^(?:[A-Za-z_]\w*\/)*[A-Za-z_]\w*\.py$/.test(path)) {
      library["src/lib/" + path] = files[path];
    }
  }
  // Only byte-identical app libraries use generated code. Imported overrides
  // keep their Python implementation, and every runtime creates fresh modules.
  installPythonPrecompiled(library);
  Sk.configure({
    __future__: Sk.python3,
    execLimit: 8000,
    output() {},
    read(path) {
      if (Object.prototype.hasOwnProperty.call(library, path)) return library[path];
      if (packageData == null && readSibling && !standardRoots.has(path.substring('src/lib/'.length).split(/[/.]/)[0]) &&
          /^src\/lib\/(?:[A-Za-z_]\w*\/)*[A-Za-z_]\w*\.py$/.test(path)) {
        const text = readSibling(path.substring("src/lib/".length));
        if (typeof text === "string") return text;
        if (text && typeof text.then === 'function') {
          return Sk.misceval.promiseToSuspension(text.then(value => {
            if (typeof value !== 'string') throw new Error('Python 模块不可用：' + path);
            library[path] = value;
            return value;
          }));
        }
      }
      throw new Error("Python 模块不可用：" + path);
    }
  });
  localPackage.activate();
  let instance;
  const py = Sk.ffi.remapToPy;
  function run(call, convert = Sk.ffi.remapToJs) {
    const value = call();
    if (value && value.$isSuspension) {
      return Sk.misceval.asyncToPromise(() => value).then(convert);
    }
    return convert(value);
  }
  function invoke(name, args, optional, convert) {
    // Keep the execution limit, but exclude time spent browsing between calls.
    // A retained Spider must receive a fresh clock for each top-level operation.
    Sk.execStart = Sk.lastYield = Date.now();
    const fn = instance.tp$getattr(new Sk.builtin.str(name));
    if (!fn && optional) return {};
    if (!fn) throw new Error("Python Spider 缺少 " + name);
    return run(() => Sk.misceval.callsimOrSuspendArray(fn, args.map(x => py(x))), convert);
  }
  function proxyResult(value) {
    if (!(value instanceof Sk.builtin.list || value instanceof Sk.builtin.tuple) ||
        value.v.length < 3 || value.v.length > 5) {
      throw new Error('Python proxy requires [status, MIME, body, headers?, base64?]');
    }
    const result = Sk.ffi.remapToJs(value);
    if (!Number.isInteger(result[0]) || result[0] < 200 || result[0] > 599 ||
        typeof result[1] !== 'string' || !result[1] || result[1].length > 256 || /[\r\n\0]/.test(result[1]) ||
        (result.length === 5 && result[4] !== 0 && result[4] !== 1)) {
      throw new Error('Invalid Python proxy response metadata');
    }
    if (result.length > 3 && result[3] != null &&
        (typeof result[3] !== 'object' || Array.isArray(result[3]) ||
          Object.keys(result[3]).length > 64 || Object.values(result[3]).some(v => typeof v !== 'string'))) {
      throw new Error('Invalid Python proxy response headers');
    }
    const body = value.v[2];
    if (body instanceof Sk.builtin.bytes) {
      const input = body.v;
      if (input.length > 6 * 1024 * 1024) throw new Error('Python proxy body exceeds 6 MiB');
      const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      let encoded = '';
      for (let i = 0; i < input.length; i += 3) {
        const bits = (input[i] << 16) | ((input[i + 1] || 0) << 8) | (input[i + 2] || 0);
        encoded += alphabet[(bits >>> 18) & 63] + alphabet[(bits >>> 12) & 63] +
          (i + 1 < input.length ? alphabet[(bits >>> 6) & 63] : '=') +
          (i + 2 < input.length ? alphabet[bits & 63] : '=');
      }
      // Python bytes would otherwise become Uint8Array, whose JSON form has
      // numeric object keys. Keep a portable, explicit five-item wire result.
      return [result[0], result[1], encoded, result.length > 3 ? result[3] : null, 1];
    }
    if (typeof result[2] !== 'string' && !(Array.isArray(result[2]) &&
        result[2].length <= 6 * 1024 * 1024 && result[2].every(v => Number.isInteger(v) && v >= 0 && v <= 255))) {
      throw new Error('Python proxy body must be text or bytes');
    }
    return result;
  }
  return {
    init(ext) {
      Sk.execStart = Sk.lastYield = Date.now();
      const boot = Sk.importMainWithBody("<source>", false, source, true);
      function initialize(mod) {
        if (!mod.$d.Spider) throw new Error("Python 来源缺少 Spider 类");
        const created = Sk.misceval.callsimOrSuspendArray(mod.$d.Spider, []);
        function ready(value) {
          instance = value;
          return invoke("init", [ext], true);
        }
        return created && created.$isSuspension
          ? Sk.misceval.asyncToPromise(() => created).then(ready) : ready(created);
      }
      return boot && boot.$isSuspension
        ? Sk.misceval.asyncToPromise(() => boot).then(initialize) : initialize(boot);
    },
    home(filter) { return invoke("homeContent", [filter]); },
    homeVod() { return invoke("homeVideoContent", [], true); },
    category(id, page, filter, ext) {
      return invoke("categoryContent", [id, String(page), filter, ext]);
    },
    detail(id) { return invoke("detailContent", [[id]]); },
    search(word, quick, page) {
      const fn = instance.tp$getattr(new Sk.builtin.str("searchContent"));
      const argc = fn && fn.im_func && fn.im_func.co_argcount;
      return invoke("searchContent", argc >= 4 ? [word, quick, String(page)] : [word, quick]);
    },
    play(flag, id, vip) { return invoke("playerContent", [flag, id, vip]); },
    liveContent(url) { return invoke("liveContent", [url]); },
    proxy(params) {
      const legacy = instance.tp$getattr(new Sk.builtin.str('localProxy'));
      const name = legacy !== undefined && legacy !== Sk.builtin.none.none$ ? 'localProxy' : 'proxy';
      return invoke(name, [params], false, proxyResult);
    },
  };
}
