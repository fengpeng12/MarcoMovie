// Execute the shared Python assets, not a reimplementation of the source host.
// Both sync Android-style and Promise desktop/Apple-style req bridges are used.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const http = require('node:http');
// The embedded iOS Node runs without WebAssembly; its HTTP test transport must
// use the same socket-backed fetch instead of Node's WASM-dependent global fetch.
const fetch = require('../shared/catpaw/fetch.cjs').default;

const source = `
import base64, requests
from requests.exceptions import HTTPError
from urllib.parse import quote, quote_plus, unquote, unquote_plus, urlencode, parse_qs, parse_qsl, urlparse, urlsplit, urljoin, urlunparse
from base.spider import Spider as Base
class Spider(Base):
    def init(self, ext): self.origin = ext
    def homeContent(self, filter):
        raw = bytes([0, 255, 128, 1])
        p = urlparse('https://user:pass@[::1]:8443/a/b;params?x=1#frag')
        return {'binary':list(base64.b64decode(base64.b64encode(raw))),
            'url64':base64.urlsafe_b64encode(raw).decode('ascii'),
            'url64decoded':list(base64.urlsafe_b64decode('AP-AAQ==')),
            'quoted':quote('中文 /+!'), 'plus':quote_plus('a +b'),
            'unquoted':unquote('%E4%B8%AD%E6%96%87+'), 'unplus':unquote_plus('a+%2Bb'),
            'query':urlencode([('k', ['a b','c']),('blank','')], doseq=True),
            'parsed':parse_qs('k=a+b&k=c&blank=', keep_blank_values=True),
            'pairs':parse_qsl('x=1&x=2'),
            'host':p.hostname, 'port':p.port, 'user':p.username, 'password':p.password,
            'roundtrip':urlunparse(p), 'joined':urljoin('https://source.example/a/b?old=1', '../c?q=1#f'),
            'emptyquery':urljoin('https://source.example/a?old=1', '?'),
            'rootjoin':urljoin('https://source.example/a/b', '../../'),
            'doublepath':urljoin('https://source.example/a', '/a//b'),
            'rawquote':quote(bytes([255,32])),
            'scheme':urljoin('https://source.example/a/b', '//other.example/path'),
            'fragment':urlsplit('https://source.example/p#f', allow_fragments=False).path}
    def categoryContent(self, tid, pg, filter, extend):
        r = self.fetch(self.origin + '/query?old=1#fragment', params=[('wd',['中文 test','two']), ('skip',None),('flag',True),('raw',b'a b')], timeout=2.5, allow_redirects=False)
        with r:
            return {'data':r.json(), 'contentType':r.headers['Content-Type'], 'ok':r.ok, 'status':r.status_code}
    def searchContent(self, key, quick, pg='1'):
        r = self.post(self.origin + '/form', data=[('wd',key),('pg',pg),('format',['mp4','mkv'])], headers={'content-type':'application/custom-form'})
        return r.json()
    def detailContent(self, ids):
        return requests.post(self.origin + '/json', json={'id':ids[0],'title':'中文'}, cookies={'session':'fixture'}, auth=('fixture','secret')).json()
    def playerContent(self, flag, id, vip):
        r = requests.get(self.origin + '/binary')
        uploaded = requests.post(self.origin + '/binary-upload', data=bytes([0,255,128,65]), headers={'Content-Type':'application/octet-stream'}).json()
        empty = requests.post(self.origin + '/empty-upload', data=b'').json()
        return {'bytes':list(r.content), 'head':requests.head(self.origin + '/head').status_code, 'uploaded':uploaded, 'empty':empty}
    def homeVideoContent(self):
        errors = []
        try: requests.get(self.origin + '/missing').raise_for_status()
        except HTTPError: errors.append('http')
        try: base64.b64decode('bad!base64', validate=True)
        except ValueError: errors.append('base64')
        try: base64.b64decode('YQ')
        except ValueError: errors.append('padding')
        try: requests.get(self.origin + '/unused', timeout=0)
        except ValueError: errors.append('timeout')
        try: requests.get(self.origin + '/unused', files={})
        except NotImplementedError: errors.append('unsupported')
        try: requests.post(self.origin + '/unused', data=b'x' * (6 * 1024 * 1024 + 1))
        except ValueError: errors.append('body-limit')
        return errors
`;

function context(req, script = source, inspect = () => {}, readSibling) {
  const context = vm.createContext({req, console, setTimeout, clearTimeout});
  const dependencies = fs.readFileSync(path.join(__dirname, '../android/src/main/assets/python-host/parser.js'), 'utf8');
  vm.runInContext("globalThis.__moviePythonHtmlParser=function(){const navigator={appName:'Netscape'};\n" + dependencies +
    "\nglobalThis.__moviePythonHtmlParser=()=>MoviePythonHtml;return MoviePythonHtml;};", context);
  for (const name of ['skulpt.min.js', 'skulpt-stdlib.js', 'compiled-modules.js', 'html.js', 'regex.js', 'json.js', 'io.js', 'spider.js']) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, '../android/src/main/assets/python-host', name), 'utf8'), context, {filename:name});
  }
  inspect(context);
  return context.createPythonSpider(script, {}, readSibling);
}

function response(url, options, body) {
  const parsed = new URL(url);
  switch (parsed.pathname) {
    case '/query':
      assert.equal(options.method, 'GET');
      assert.equal(options.timeout, 2500);
      assert.equal(options.redirect, 0);
      assert.deepEqual(parsed.searchParams.getAll('wd'), ['中文 test', 'two']);
      assert.equal(parsed.searchParams.get('flag'), 'True');
      assert.equal(parsed.searchParams.get('raw'), 'a b');
      assert.equal(parsed.searchParams.has('skip'), false);
      assert.equal(parsed.searchParams.get('old'), '1');
      return {code:200, content:Buffer.from(JSON.stringify({list:[{vod_id:'1',vod_name:'Python fixture'}]})), headers:{'content-type':'application/json'}};
    case '/form':
      assert.equal(options.method, 'POST');
      assert.equal(options.headers['content-type'], 'application/custom-form');
      assert.equal(options.headers['Content-Type'], undefined);
      assert.equal(body, 'wd=keyword+with+space&pg=3&format=mp4&format=mkv');
      return {code:200, content:Buffer.from(body), headers:{'content-type':'application/json'}};
    case '/json':
      assert.equal(options.headers['Authorization'], 'Basic Zml4dHVyZTpzZWNyZXQ=');
      assert.equal(options.headers['Cookie'], 'session=fixture');
      assert.deepEqual(JSON.parse(body), {id:'42',title:'中文'});
      return {code:200, content:Buffer.from(body), headers:{'content-type':'application/json'}};
    case '/binary': return {code:200, content:Buffer.from([0,255,128,1]), headers:{'content-type':'application/octet-stream'}};
    case '/binary-upload':
      assert.equal(options.method, 'POST');
      assert.deepEqual(Array.from(body), [0,255,128,65]);
      return {code:200, content:Buffer.from(JSON.stringify(Array.from(body))), headers:{'content-type':'application/json'}};
    case '/empty-upload':
      assert.equal(options.method, 'POST');
      assert.equal(body.length, 0);
      return {code:200, content:Buffer.from('[]'), headers:{'content-type':'application/json'}};
    case '/head':
      assert.equal(options.method, 'HEAD');
      assert.equal(options.redirect, 0);
      return {code:204, content:Buffer.alloc(0), headers:{}};
    case '/missing': return {code:404, content:Buffer.from('missing'), headers:{}};
    default: throw new Error('Unexpected source request');
  }
}

async function exercise(req, origin, mode) {
  const spider = context(req);
  await spider.init(origin);
  const home = JSON.parse(JSON.stringify(await spider.home(true)));
  assert.deepEqual(home, {
    binary:[0,255,128,1], url64:'AP-AAQ==', url64decoded:[0,255,128,1],
    quoted:'%E4%B8%AD%E6%96%87%20/%2B%21', plus:'a+%2Bb', unquoted:'中文+', unplus:'a +b',
    query:'k=a+b&k=c&blank=', parsed:{k:['a b','c'], blank:['']}, pairs:[['x','1'],['x','2']],
    host:'::1', port:8443, user:'user', password:'pass',
    roundtrip:'https://user:pass@[::1]:8443/a/b;params?x=1#frag', joined:'https://source.example/c?q=1#f',
    emptyquery:'https://source.example/a?old=1', rootjoin:'https://source.example/',
    doublepath:'https://source.example/a//b', rawquote:'%FF%20',
    scheme:'https://other.example/path', fragment:'/p#f',
  });
  const category = await spider.category('1', 1, true, {});
  assert.equal(category.data.list[0].vod_name, 'Python fixture');
  assert.equal(category.contentType, 'application/json');
  assert.equal(category.ok, true);
  assert.equal(category.status, 200);
  assert.equal(await spider.search('keyword with space', false, 3), 'wd=keyword+with+space&pg=3&format=mp4&format=mkv');
  assert.deepEqual(JSON.parse(JSON.stringify(await spider.detail('42'))), {id:'42',title:'中文'});
  assert.deepEqual(JSON.parse(JSON.stringify(await spider.play('line','episode',[]))), {bytes:[0,255,128,1],head:204,uploaded:[0,255,128,65],empty:[]});
  assert.deepEqual(Array.from(await spider.homeVod()), ['http','base64','padding','timeout','unsupported','body-limit']);
  console.log('PASS Python import, URL/byte codecs, catalogue/search/detail/play HTTP contracts and errors (' + mode + ')');
}

const sessionSource = `
import requests
from requests.cookies import RequestsCookieJar
class Spider:
    def init(self, ext): self.origin = ext
    def homeContent(self, filter):
        with requests.Session() as s:
            s.headers.update({'X-Session':'active', 'X-Remove':'gone'})
            s.params = {'persistent':'yes'}
            login = s.get(self.origin + '/login', headers={'x-remove':None})
            assert login.cookies['sid'] == 'fixture'
            assert s.cookies.get('sid') == 'fixture'
            authenticated = s.get(self.origin + '/auth/resource', params={'once':'query'}).json()
            outside = s.get(self.origin + '/other').json()
            boundary = s.get(self.origin + '/authentic').json()
            isolated = requests.Session().get(self.origin + '/auth/resource').json()
            override = s.get(self.origin + '/auth/resource', cookies={'once':'cookie'}).json()
            normal = s.get(self.origin + '/auth/resource').json()
            redirected = s.get(self.origin + '/redirect')
            assert len(redirected.history) == 1
            cross = s.get(self.origin + '/cross', headers={'Authorization':'Bearer fixture'}).json()
            s.get(self.origin + '/expire')
            expired = s.get(self.origin + '/auth/resource').json()
            s.cookies.set('manual','value', domain='127.0.0.1', path='/')
            s.close()
            reused = s.get(self.origin + '/auth/resource').json()
            assert s.cookies.get_dict()['manual'] == 'value'
            s.cookies.clear()
            cleared = s.get(self.origin + '/auth/resource').json()
            try:
                s.max_redirects = 1
                s.get(self.origin + '/loop')
            except requests.exceptions.TooManyRedirects:
                limit = True
            return {'authenticated':authenticated, 'outside':outside, 'boundary':boundary,
                'isolated':isolated, 'override':override, 'normal':normal,
                'redirected':redirected.json(), 'cross':cross, 'expired':expired,
                'reused':reused, 'cleared':cleared, 'limit':limit}
`;

function sessionResponse(url, options, crossOrigin) {
  const parsed = new URL(url), h = {};
  for (const [key, value] of Object.entries(options.headers || {})) h[key.toLowerCase()] = value;
  let headers = {}, code = 200;
  if (parsed.pathname === '/login') {
    assert.equal(h['x-session'], 'active');
    assert.equal(h['x-remove'], undefined);
    headers['set-cookie'] = [
      'sid=fixture; Path=/auth; HttpOnly',
      'root=all; Path=/; Expires=Wed, 01 Jan 2031 00:00:00 GMT',
      'bad=reject; Domain=unrelated.example; Path=/',
      'secure=reject; Secure; Path=/',
    ];
  } else if (parsed.pathname === '/redirect') {
    code = 302; headers = {'location':'/auth/resource', 'set-cookie':'redirect=kept; Path=/auth'};
  } else if (parsed.pathname === '/cross') {
    code = 302; headers = {'location':crossOrigin + '/auth/resource'};
  } else if (parsed.pathname === '/expire') {
    headers['set-cookie'] = 'sid=deleted; Path=/auth; Max-Age=0';
  } else if (parsed.pathname === '/loop') {
    code = 302; headers.location = '/loop';
  }
  return {code, url, headers, content:Buffer.from(JSON.stringify({cookie:h.cookie || '', auth:h.authorization || '',
    session:h['x-session'] || '', persistent:parsed.searchParams.get('persistent'), once:parsed.searchParams.get('once')})).toString('base64')};
}

async function exerciseSession(req, origin, mode) {
  const spider = context(req, sessionSource);
  await spider.init(origin);
  const result = JSON.parse(JSON.stringify(await spider.home(true)));
  assert.equal(result.authenticated.cookie, 'sid=fixture; root=all');
  assert.equal(result.authenticated.session, 'active');
  assert.equal(result.authenticated.persistent, 'yes');
  assert.equal(result.authenticated.once, 'query');
  assert.equal(result.outside.cookie, 'root=all');
  assert.equal(result.boundary.cookie, 'root=all');
  assert.equal(result.isolated.cookie, '');
  assert.equal(result.override.cookie, 'sid=fixture; root=all; once=cookie');
  assert.equal(result.normal.cookie, 'sid=fixture; root=all');
  assert.equal(result.redirected.cookie, 'sid=fixture; redirect=kept; root=all');
  assert.equal(result.cross.cookie, '');
  assert.equal(result.cross.auth, '');
  assert.equal(result.expired.cookie, 'redirect=kept; root=all');
  assert.equal(result.reused.cookie, 'redirect=kept; root=all; manual=value');
  assert.equal(result.cleared.cookie, '');
  assert.equal(result.limit, true);
  console.log('PASS Python Session headers, cookies, redirects, isolation, expiry and close (' + mode + ')');
}

async function main() {
  for (const asynchronous of [false, true]) {
    let requests = 0;
    const construct = context(() => {
      requests++;
      const response = {code:200, url:'https://fixture.invalid/bootstrap', headers:{},
        content:Buffer.from('{"title":"constructor ready"}').toString('base64')};
      return asynchronous ? Promise.resolve(response) : response;
    }, `
import requests
class Spider:
 def __init__(self): self.title = requests.get('https://fixture.invalid/bootstrap').json()['title']
 def init(self, ext): self.title += ext
 def homeContent(self, filter): return self.title
`);
    const initialized = construct.init(' / initialized');
    assert.equal(Boolean(initialized && initialized.then), asynchronous);
    await initialized;
    assert.equal(await construct.home(true), 'constructor ready / initialized');
    assert.equal(await construct.home(true), 'constructor ready / initialized');
    assert.equal(requests, 1);
  }
  console.log('PASS Python synchronous and asynchronous constructor completes before init and retains state');
  const reads = [];
  const asynchronous = context(() => { throw Error('unexpected HTTP'); }, `
from remotehelper import title
class Spider:
 def homeContent(self, filter):
  from later import value
  return [title, value]
`, () => {}, async name => {
    reads.push(name);
    return {'remotehelper.py':"title = 'remote module'", 'later.py':'value = 42'}[name] ?? null;
  });
  await asynchronous.init('');
  assert.deepEqual(Array.from(await asynchronous.home(true)), ['remote module', 42]);
  assert.deepEqual(Array.from(await asynchronous.home(true)), ['remote module', 42]);
  assert.equal(reads.filter(v => v === 'later.py').length, 1);
  console.log('PASS Python asynchronous sibling imports, late imports and module reuse');
  const htmlSource = fs.readFileSync(path.join(__dirname, 'fixtures/python_html_contract.py'), 'utf8');
  const htmlExpected = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/python_html_expected.json'), 'utf8'));
  const htmlSpider = context(() => { throw Error('HTML parser must not make network requests'); }, htmlSource);
  await htmlSpider.init('');
  assert.deepEqual(JSON.parse(JSON.stringify(await htmlSpider.home(true))), htmlExpected);
  const htmlBounds = context(() => { throw Error('unexpected HTTP'); }, `
from bs4 import BeautifulSoup
class Spider:
 def homeContent(self, filter):
  errors = []
  for operation in range(7):
   try:
    if operation == 0: BeautifulSoup('x' * (2 * 1024 * 1024 + 1), 'html.parser')
    if operation == 1: BeautifulSoup('<i></i>' * 50001, 'html.parser')
    if operation == 2: BeautifulSoup('<i></i>' * 10001, 'html.parser').select('i')
    if operation == 3: BeautifulSoup('<p>x</p>', 'html.parser').select('[')
    if operation == 4: BeautifulSoup('<p>x</p>', 'html.parser').select('x' * 2049)
    if operation == 5: BeautifulSoup('<p>x</p>', 'lxml')
    if operation == 6: BeautifulSoup(42, 'html.parser')
   except (ValueError, NotImplementedError, TypeError): errors.append(operation)
  soup = BeautifulSoup('<i>first</i>' + '<i></i>' * 10001, 'html.parser')
  assert soup.select_one('i').text == 'first'
  return errors
`);
  await htmlBounds.init('');
  assert.deepEqual(Array.from(await htmlBounds.home(true)), [0, 1, 2, 3, 4, 5, 6]);
  console.log('PASS Python local HTML selectors, text, entities and attributes against CPython/BeautifulSoup; size and feature limits');
  let retainedRuntime;
  const retained = context(() => { throw new Error('unexpected request'); }, `class Spider:
 def init(self, ext): self.count = 0
 def homeContent(self, filter):
  self.count += 1
  return self.count
`, runtime => { retainedRuntime = runtime; });
  await retained.init('');
  assert.equal(await retained.home(true), 1);
  retainedRuntime.Sk.execStart -= 9000;
  retainedRuntime.Sk.lastYield -= 9000;
  assert.equal(await retained.home(true), 2);
  assert.equal(retainedRuntime.Sk.execLimit, 8000);
  console.log('PASS retained Python renews operation clocks without removing its execution limit');
  const cookieObjects = context(() => { throw new Error('Cookie object fixture must stay offline'); }, `import requests
from requests.cookies import CookieConflictError
class Spider:
 def homeContent(self, filter):
  s = requests.Session()
  s.cookies.set('sid','one',domain='one.example.test',path='/auth',secure=True,expires=1924992000)
  s.cookies.set('sid','two',domain='two.example.test',path='/',secure=False)
  cookies = list(s.cookies)
  assert len(cookies) == 2
  assert cookies[0].name == 'sid' and cookies[0].value == 'one'
  assert cookies[0].domain == 'one.example.test' and cookies[0].path == '/auth'
  assert cookies[0].secure and cookies[0].expires == 1924992000 and cookies[0].domain_specified
  assert cookies[1].expires is None and not cookies[1].secure
  assert {(c.domain,c.path):c.value for c in s.cookies} == {('one.example.test','/auth'):'one',('two.example.test','/'):'two'}
  collision = False
  try: s.cookies['sid']
  except CookieConflictError: collision = True
  assert collision
  assert s.cookies.get('sid',domain='two.example.test',path='/') == 'two'
  cookies[0].value = 'updated'
  assert s.cookies.get('sid',domain='one.example.test') == 'updated'
  copy = s.cookies.copy()
  list(copy)[0].value = 'copy-only'
  assert s.cookies.get('sid',domain='one.example.test') == 'updated'
  isolated = requests.Session()
  assert not list(isolated.cookies)
  s.cookies.clear(domain='two.example.test',path='/',name='sid')
  assert dict(s.cookies) == {'sid':'updated'}
  return True
`);
  await cookieObjects.init('');
  assert.equal(await cookieObjects.home(true), true);
  console.log('PASS Python Cookie objects, mapping compatibility, duplicate domains, mutation and copy/session isolation');
  const scoped = context((url, options) => {
    const headers = url.endsWith('/a/login') ? {'set-cookie':[
      'host=local; Path=/', 'domain=shared; Domain=.example.test; Path=/',
      'secure=secret; Secure; Path=/', 'default=local',
      'old=gone; Expires=Wed, 01 Jan 2000 00:00:00 GMT',
      'foreign=no; Domain=unrelated.test; Path=/',
      '__Host-bad=no; Domain=.example.test; Secure; Path=/',
      '__Secure-bad=no; Path=/',
    ].join(', ')} : {};
    return {code:200, url, headers, content:Buffer.from(JSON.stringify(options.headers.cookie || options.headers.Cookie || '')).toString('base64')};
  }, `import requests
class Spider:
 def homeContent(self, filter):
  s = requests.Session()
  s.get('https://sub.example.test/a/login')
  same = s.get('https://sub.example.test/a/resource').json()
  sibling = s.get('https://other.example.test/a/resource').json()
  plain = s.get('http://sub.example.test/a/resource').json()
  outside = s.get('https://sub.example.test/ab').json()
  invalid = False
  try: s.cookies.set('bad\\r\\nname','value')
  except ValueError: invalid = True
  return [same, sibling, plain, outside, invalid]
`);
  await scoped.init('');
  assert.deepEqual(JSON.parse(JSON.stringify(await scoped.home(true))), [
    'default=local; host=local; domain=shared; secure=secret', 'domain=shared',
    'default=local; host=local; domain=shared', 'host=local; domain=shared; secure=secret', true,
  ]);
  console.log('PASS Python Session host-only/domain/secure/default-path/expiry and invalid-cookie scoping');
  for (const asyncBridge of [false, true]) {
    const errorSpider = context(() => {
      const error = new Error('request timeout fixture');
      if (asyncBridge) return Promise.reject(error);
      throw error;
    }, `import requests, json\nfrom requests.exceptions import Timeout\nclass Spider:\n def homeContent(self, filter):\n  errors = []\n  try: requests.get('https://source.example/timeout')\n  except Timeout: errors.append('timeout')\n  try: json.loads('not JSON')\n  except ValueError: errors.append('json')\n  return errors\n`);
    await errorSpider.init('');
    assert.deepEqual(Array.from(await errorSpider.home(true)), ['timeout','json']);
  }
  await exercise((url, options) => {
    assert.equal(options.buffer, 2);
    if (options.bodyBase64 !== undefined) assert.equal('data' in options, false);
    const r = response(url, options, options.bodyBase64 === undefined ? options.data : Buffer.from(options.bodyBase64, 'base64'));
    // The form echo is a JSON string, to exercise Response.json as well.
    if (new URL(url).pathname === '/form') r.content = Buffer.from(JSON.stringify(r.content.toString()));
    return {...r, content:r.content.toString('base64')};
  }, 'https://source.example', 'synchronous req');
  await exerciseSession((url, options) => sessionResponse(url, options, 'http://127.0.0.2'), 'http://127.0.0.1', 'synchronous req');
  const serverErrors = [];
  const server = http.createServer(async (request, reply) => {
    try {
      const chunks = [];
      for await (const chunk of request) chunks.push(chunk);
      const parsed = new URL(request.url, 'http://source.example');
      // Transport-only assertions were made before calling fetch; recover the
      // same documented options for server-side content assertions.
      const headers = {...request.headers, Authorization:request.headers.authorization, Cookie:request.headers.cookie};
      const raw = Buffer.concat(chunks);
      const r = response(parsed.toString(), {method:request.method, timeout:2500, redirect:0, headers}, parsed.pathname.endsWith('-upload') ? raw : raw.toString());
      reply.writeHead(r.code, r.headers);
      reply.end(parsed.pathname === '/form' ? JSON.stringify(r.content.toString()) : r.content);
    } catch (error) {
      serverErrors.push(error); reply.writeHead(500); reply.end('fixture failed');
    }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    await exercise(async (url, options) => {
      assert.equal(options.buffer, 2);
      if (new URL(url).pathname === '/query') { assert.equal(options.timeout, 2500); assert.equal(options.redirect, 0); }
      const result = await fetch(url, {method:options.method, headers:options.headers,
        body:options.bodyBase64 === undefined ? options.data ?? undefined : Buffer.from(options.bodyBase64, 'base64'), redirect:options.redirect === 0 ? 'manual' : 'follow'});
      return {code:result.status, headers:Object.fromEntries(result.headers), content:Buffer.from(await result.arrayBuffer()).toString('base64')};
    }, 'http://127.0.0.1:' + server.address().port, 'Promise req over local HTTP');
    assert.deepEqual(serverErrors, []);
  } finally {
    await new Promise(resolve => server.close(resolve));
  }
  const cookieServer = http.createServer((request, reply) => {
    const origin = 'http://' + request.headers.host;
    const r = sessionResponse(new URL(request.url, origin).toString(), {headers:request.headers},
      'http://127.0.0.2:' + cookieServer.address().port);
    reply.writeHead(r.code, r.headers);
    reply.end(Buffer.from(r.content, 'base64'));
  });
  await new Promise(resolve => cookieServer.listen(0, '0.0.0.0', resolve));
  try {
    await exerciseSession(async (url, options) => {
      assert.equal(options.redirect, 0);
      const r = await fetch(url, {method:options.method, headers:options.headers, body:options.data ?? undefined, redirect:'manual'});
      const headers = Object.fromEntries(r.headers);
      // Android and Dart flatten repeated response headers; retain every cookie.
      const cookies = r.headers.raw()['set-cookie'] || [];
      if (cookies.length) headers['set-cookie'] = cookies.join(', ');
      return {code:r.status, url:r.url, headers, content:Buffer.from(await r.arrayBuffer()).toString('base64')};
    }, 'http://127.0.0.1:' + cookieServer.address().port, 'Promise req over local HTTP');
  } finally {
    await new Promise(resolve => cookieServer.close(resolve));
  }
}
main().catch(error => { console.error(String(error)); if (error.stack) console.error(error.stack); process.exitCode = 1; });
