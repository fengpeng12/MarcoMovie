// Run the shared Python ABI itself. Fixtures have no imported subscriptions,
// private endpoints, native Python dependencies, or external network access.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const base = 'http://127.0.0.1:18345/_spider/' + 'a'.repeat(43) + '/proxy?do=py&siteKey=fixture-source';
const directory = path.join(__dirname, '../android/src/main/assets/python-host');
const files = ['skulpt.min.js', 'skulpt-stdlib.js', 'compiled-modules.js', 'html.js', 'regex.js', 'json.js', 'io.js', 'spider.js']
  .map(name => [name, fs.readFileSync(path.join(directory, name), 'utf8')]);
let checks = 0;

function host(source, {url = base, req = () => { throw Error('unexpected HTTP'); }} = {}) {
  const context = vm.createContext({req, console, setTimeout, clearTimeout});
  if (url !== null) context.__movieProxyBase = url;
  for (const [name, text] of files) vm.runInContext(text, context, {filename: name});
  return {context, spider: context.createPythonSpider(source)};
}
function plain(value) { return JSON.parse(JSON.stringify(value)); }
async function fails(call, pattern) {
  let failed = false;
  try { await call(); } catch (error) {
    failed = true;
    assert.match(String(error), pattern);
  }
  assert.equal(failed, true, 'operation must fail explicitly');
}
async function check(name, run) { await run(); checks++; console.log('PASS ' + name); }

const legacy = `
from base.spider import Spider as Base
class Spider(Base):
    def init(self, ext):
        self.label = ext
        self.calls = 0
    def playerContent(self, flag, id, vip):
        return {'parse':0, 'url':self.getProxyUrl({'id':id, 'mode':flag})}
    def localProxy(self, params):
        self.calls += 1
        response = self.fetch('https://source.example/bytes', headers={'Range':params['range']})
        return [response.status_code, 'video/mp2t', response.content,
            {'Content-Range':response.headers['Content-Range'], 'X-Init':self.label,
             'X-Calls':str(self.calls), 'X-Id':params['id']}]
`;

async function main() {
  for (const asynchronous of [false, true]) {
    await check('retained legacy state, request dictionary and binary result (' + (asynchronous ? 'Suspension' : 'sync') + ')', async () => {
      let requests = 0;
      const {spider} = host(legacy, {req(url, options) {
        requests++;
        assert.equal(url, 'https://source.example/bytes');
        assert.equal(options.headers.Range, 'bytes=4-7');
        assert.equal(options.buffer, 2);
        const result = {code:206, headers:{'content-range':'bytes 4-7/100'}, content:'AP+AQQ=='};
        return asynchronous ? Promise.resolve(result) : result;
      }});
      await spider.init('retained fixture');
      const play = await spider.play('binary', 'episode &中', []);
      const url = new URL(play.url);
      assert.equal(url.origin, new URL(base).origin);
      assert.equal(url.searchParams.get('id'), 'episode &中');
      assert.equal(url.searchParams.get('do'), 'py');
      for (let call = 1; call <= 2; call++) {
        const pending = spider.proxy({id:'episode &中', range:'bytes=4-7'});
        assert.equal(!!pending?.then, asynchronous);
        const result = plain(await pending);
        assert.deepEqual(result, [206, 'video/mp2t', 'AP+AQQ==',
          {'Content-Range':'bytes 4-7/100', 'X-Init':'retained fixture', 'X-Calls':String(call), 'X-Id':'episode &中'}, 1]);
        assert.deepEqual(Array.from(Buffer.from(result[2], 'base64')), [0,255,128,65]);
      }
      assert.equal(requests, 2);
    });
  }
  await check('legacy URL helper supports bool, dict coercion and immutable parameters', async () => {
    const {spider} = host(`
from base.spider import Spider as Base
class Spider(Base):
    def homeContent(self, filter):
        params = {'url':'https://media.example/a b?x=中&y=+'}
        return [self.getProxyUrl(), self.getProxyUrl(False),
          self.getProxyUrl(params, False), self.getProxyUrl([('number', 42)]), params]
`);
    await spider.init('');
    const result = plain(await spider.home(true));
    assert.equal(result[0], base);
    assert.equal(result[1], base);
    assert.equal(new URL(result[2]).searchParams.get('url'), result[4].url);
    assert.equal(new URL(result[3]).searchParams.get('number'), '42');
    assert.deepEqual(result[4], {url:'https://media.example/a b?x=中&y=+'});
  });
  await check('new proxyUrl and proxy entry work without a legacy base stub', async () => {
    const {spider} = host(`
from base.spider import Spider as Base
class Spider(Base):
    def playerContent(self, flag, id, vip):
        return {'url':self.proxyUrl({'id':id}, local=False), 'parse':0}
    def proxy(self, params):
        return (200, 'text/plain; charset=utf-8', params['id'])
`);
    await spider.init('');
    const play = plain(await spider.play('', 'new 中', []));
    assert.equal(new URL(play.url).hostname, '127.0.0.1');
    assert.equal(new URL(play.url).searchParams.get('id'), 'new 中');
    assert.deepEqual(plain(await spider.proxy({id:'new 中'})), [200, 'text/plain; charset=utf-8', 'new 中']);
  });
  await check('actual legacy method wins when both entries exist', async () => {
    const {spider} = host(`
from base.spider import Spider as Base
class Spider(Base):
    def localProxy(self, params): return [200, 'text/plain', 'legacy']
    def proxy(self, params): raise RuntimeError('wrong new entry')
`);
    await spider.init('');
    assert.equal((await spider.proxy({}))[2], 'legacy');
  });
  await check('new URL helper enforces string dictionary and boolean local flag', async () => {
    const {spider} = host(`
from base.spider import Spider as Base
class Spider(Base):
    def homeContent(self, filter):
        errors = []
        for params in [False, [('x','value')], {'x':1}, {1:'value'}]:
            try: self.proxyUrl(params)
            except TypeError: errors.append('params')
        try: self.proxyUrl({}, local=1)
        except TypeError: errors.append('local')
        return errors
`);
    await spider.init('');
    assert.deepEqual(plain(await spider.home(true)), ['params','params','params','params','local']);
  });
  await check('both helpers reject reserved route parameters', async () => {
    const {spider} = host(`
from base.spider import Spider as Base
class Spider(Base):
    def homeContent(self, filter):
        errors = []
        for key in ['do', 'siteKey']:
            try: self.getProxyUrl({key:'other'})
            except ValueError: errors.append('legacy')
            try: self.proxyUrl({key:'other'})
            except ValueError: errors.append('new')
        return errors
`);
    await spider.init('');
    assert.deepEqual(plain(await spider.home(true)), ['legacy','new','legacy','new']);
  });
  await check('missing or invalid host bridge is explicit and never invents a port', async () => {
    const source = `
from base.spider import Spider as Base
class Spider(Base):
    def homeContent(self, filter): return {'class':[]}
    def playerContent(self, flag, id, vip): return {'url':self.getProxyUrl()}
    def localProxy(self, params): return [200, 'text/plain', 'fixture']
`;
    for (const url of [null, 'https://127.0.0.1:18345/proxy?do=py&siteKey=x',
      'http://0.0.0.0:18345/proxy?do=py&siteKey=x',
      'http://127.0.0.1:65536/proxy?do=py&siteKey=x',
      'http://127.0.0.1:18345/proxy?do=py']) {
      const {spider} = host(source, {url});
      await spider.init('');
      assert.deepEqual(plain(await spider.home(true)), {class:[]});
      await fails(() => spider.play('', '', []), /NotImplementedError.*bridge is unavailable/);
    }
  });
  await check('trusted route is captured before source initialization', async () => {
    const {context, spider} = host(`
from base.spider import Spider as Base
class Spider(Base):
    def playerContent(self, flag, id, vip): return {'url':self.proxyUrl()}
`);
    context.__movieProxyBase = 'http://127.0.0.1:1/changed?do=py&siteKey=other';
    await spider.init('');
    assert.equal((await spider.play('', '', [])).url, base);
  });
  await check('raw bytes become five-item Base64 including empty bytes and explicit flag', async () => {
    const {spider} = host(`
class Spider:
    def localProxy(self, params):
        if params['mode'] == 'empty': return [200, 'application/octet-stream', b'']
        if params['mode'] == 'flag': return [200, 'application/octet-stream', bytes([0,255,128]), None, 1]
        return [200, 'application/octet-stream', bytes([0,255,128])]
`);
    await spider.init('');
    assert.deepEqual(plain(await spider.proxy({mode:'empty'})), [200, 'application/octet-stream', '', null, 1]);
    for (const mode of ['raw', 'flag']) {
      assert.deepEqual(plain(await spider.proxy({mode})), [200, 'application/octet-stream', 'AP+A', null, 1]);
    }
  });
  await check('text, explicit Base64 and integer lists retain their declared meaning', async () => {
    const {spider} = host(`
class Spider:
    def localProxy(self, params):
        if params['mode'] == 'text': return [200, 'text/plain', 'AP+A']
        if params['mode'] == 'encoded': return [200, 'application/octet-stream', 'AP+A', {}, 1]
        if params['mode'] == 'error': return [404, 'text/plain', 'not found']
        return [200, 'application/octet-stream', [0,255,128]]
`);
    await spider.init('');
    assert.deepEqual(plain(await spider.proxy({mode:'text'})), [200, 'text/plain', 'AP+A']);
    assert.deepEqual(plain(await spider.proxy({mode:'encoded'})), [200, 'application/octet-stream', 'AP+A', {}, 1]);
    assert.deepEqual(plain(await spider.proxy({mode:'list'})), [200, 'application/octet-stream', [0,255,128]]);
    assert.deepEqual(plain(await spider.proxy({mode:'error'})), [404, 'text/plain', 'not found']);
  });
  await check('malformed results and absent callback do not become URL or empty successes', async () => {
    const {spider} = host(`
class Spider:
    def proxy(self, params):
        mode = params['mode']
        if mode == 'object': return {'url':'https://media.example/video.mp4'}
        if mode == 'short': return [200, 'text/plain']
        if mode == 'long': return [200, 'text/plain', '', None, 0, 1]
        if mode == 'body': return [200, 'text/plain', {'url':'https://media.example/video.mp4'}]
        if mode == 'headers': return [200, 'text/plain', '', {'X':1}]
        if mode == 'flag': return [200, 'text/plain', b'x', None, 2]
        raise RuntimeError('fixture failure')
`);
    await spider.init('');
    for (const mode of ['object','short','long','body','headers','flag','raised']) {
      await fails(() => spider.proxy({mode}), /Python proxy|fixture failure/);
    }
    const missing = host('class Spider:\n def homeContent(self, filter): return {}\n').spider;
    await missing.init('');
    await fails(() => missing.proxy({}), /Python Spider.*proxy/);
  });
  console.log('Python proxy ABI: ' + checks + ' checks passed');
}
main().catch(error => { console.error(String(error)); if (error.stack) console.error(error.stack); process.exitCode = 1; });
