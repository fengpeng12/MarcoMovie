// Owned protocol fixtures only. Node proves the shared facade, not device hosts.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const http = require('node:http');
const crypto = require('node:crypto');
if (!vm.SourceTextModule) {
  const child = require('node:child_process').spawnSync(process.execPath,
    [...process.execArgv, '--experimental-vm-modules', __filename], {stdio: 'inherit'});
  process.exit(child.status ?? 1);
}
const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'android/src/main/assets/js-host/catvod.mjs'), 'utf8');
const cryptoSource = 'const module={exports:{}};let exports=module.exports;\n' +
  fs.readFileSync(path.join(root, 'android/src/main/assets/js-host/crypto-js.js'), 'utf8') + '\nexport default module.exports;';
const records = [];
let calls = 0;
const server = http.createServer(async (req, res) => {
  const chunks = []; for await (const bytes of req) chunks.push(bytes);
  if (req.url.startsWith('/bytes')) {
    res.writeHead(206, {'content-type': 'application/octet-stream', 'x-owned': 'bytes'});
    return res.end(Buffer.from([0, 255, 128, 65]));
  }
  if (req.url === '/failed') { res.writeHead(503); return res.end('unavailable'); }
  if (req.url === '/bad-json') return res.end('not-json');
  if (req.url === '/legacy-charset') { res.setHeader('content-type', 'text/plain; charset=gbk'); return res.end('fixture'); }
  res.setHeader('content-type', 'application/json; charset=utf-8');
  res.end(JSON.stringify({method: req.method, url: req.url, headers: req.headers, body: [...Buffer.concat(chunks)]}));
});
async function run() {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const context = vm.createContext({console, __movieCatvodBridge: {
    siteKey: 'owned-source-token',
    request(url, options) {
      calls++; records.push({url, options});
      if (url.endsWith('/transport-failure')) throw new Error('owned transport failure');
      return new Promise((resolve, reject) => {
        const req = http.request(url, {method: options.method, headers: options.headers}, res => {
          const chunks = [];
          res.on('data', chunk => chunks.push(chunk));
          res.on('end', () => resolve({code: res.statusCode, headers: res.headers,
            content: Buffer.concat(chunks).toString('base64'), url}));
        });
        req.on('error', reject);
        if (options.bodyBase64 != null) req.write(Buffer.from(options.bodyBase64, 'base64'));
        req.end();
      });
    },
    proxyUrl(params) { return 'http://127.0.0.1:1234/owned/proxy?do=js&siteKey=owned-source-token&' +
      Object.entries(params).map(([k, v]) => encodeURIComponent(k) + '=' + encodeURIComponent(v)).join('&'); }
  }});
  const mod = new vm.SourceTextModule(source, {context, identifier: 'catvod'});
  const crypt = new vm.SourceTextModule(cryptoSource, {context, identifier: 'marco:catvod-crypto'});
  await mod.link(name => { assert.equal(name, 'marco:catvod-crypto'); return crypt; });
  await mod.evaluate();
  const api = mod.namespace;
  assert.deepEqual(Object.keys(api).sort(), ['Spider', 'md5X', 'net', 'page', 'proxyUrl', 'sha256X'].sort());
  assert.deepEqual(Object.keys(api.net).sort(), ['json', 'req']);
  const fixture = new vm.SourceTextModule(`import {Spider,page} from 'catvod';
    export default class extends Spider { #n=7; read(){return this.#n;} homeContent(){return {value:[1].map(this.read), key:this.siteKey, page:page([1,2,3],2,2)};} }`, {context});
  await fixture.link(() => mod); await fixture.evaluate();
  const spider = new fixture.namespace.default();
  assert.deepEqual(JSON.parse(JSON.stringify(spider.homeContent())),
    {value: [7], key: 'owned-source-token', page: {list:[3],page:2,pagecount:2,limit:2,total:3}});
  for (const text of ['', 'abc', '中文']) {
    assert.equal(api.md5X(text), crypto.createHash('md5').update(text).digest('hex'));
    assert.equal(api.sha256X(text), crypto.createHash('sha256').update(text).digest('hex'));
  }
  assert.throws(() => api.md5X(1)); assert.throws(() => api.page([], 1, 0));
  assert.equal(api.page([], 1, 5).pagecount, 1);
  const query = await api.net.json(origin + '/echo?old=1#unused', {params:{q:['中文','a b'],skip:null,flag:true}});
  assert.equal(query.url, '/echo?old=1&q=%E4%B8%AD%E6%96%87&q=a%20b&flag=true');
  for (const [options, expected] of [
    [{method:'post',data:{word:'中文'}}, Buffer.from('{"word":"中文"}')],
    [{method:'post',postType:'form',data:{word:'中 文',num:2}}, Buffer.from('word=%E4%B8%AD%20%E6%96%87&num=2')],
    [{method:'POST',headers:{'Content-Type':'application/octet-stream'},body:[0,255,128,65]},Buffer.from([0,255,128,65])],
    [{method:'PUT'},Buffer.alloc(0)],
  ]) {
    const value = await api.net.json(origin + '/echo', options);
    assert.deepEqual(Array.from(value.body), [...expected]);
  }
  const bytes = await api.net.req(origin + '/bytes', {buffer:3});
  assert.equal(Object.prototype.toString.call(bytes.content), '[object ArrayBuffer]');
  assert.deepEqual([...new Uint8Array(bytes.content)], [0,255,128,65]);
  assert.deepEqual(Array.from((await api.net.req(origin + '/bytes', {buffer:1})).content), [0,255,128,65]);
  assert.equal((await api.net.req(origin + '/bytes', {buffer:2})).content, 'AP+AQQ==');
  assert.equal((await api.net.req(origin + '/failed')).content, 'unavailable');
  await assert.rejects(api.net.json(origin + '/failed'), /HTTP 503/);
  await assert.rejects(api.net.json(origin + '/bad-json'));
  assert.match((await api.net.req(origin + '/transport-failure')).error, /owned transport failure/);
  await assert.rejects(api.net.json(origin + '/transport-failure'), /owned transport failure/);
  assert.match((await api.net.req(origin + '/legacy-charset')).error, /charset/);
  assert.equal((await api.net.req(origin + '/echo', {method:'HEADER'})).code, 200);
  assert.equal((await api.net.json(origin + '/echo', {method:'OPTIONS'})).method, 'OPTIONS');
  for (const options of [
    {cookie:true},{foo:true},{buffer:4},{buffer:'3'},{redirect:2},{timeout:0},{callTimeout:0},
    {postType:'form-data'},{method:'TRACE'},{data:{}},{method:'POST',body:[],data:{}},
    {method:'POST',body:[0]},{method:'POST',headers:{'content-type':'x'},body:[256]},
    {method:'POST',headers:{'content-type':'x'},body:[1.5]}, {params:{key:{}}},
    {headers:{'x-bad':'a\r\nb'}}, {headers:{'content-length':'4'}}, {headers:{Foo:'a',foo:'b'}},
  ]) {
    const count = calls;
    assert.ok((await api.net.req(origin, options)).error, JSON.stringify(options));
    assert.equal(calls, count, 'invalid options reached transport');
  }
  assert.throws(() => api.proxyUrl({do:'other'}));
  assert.throws(() => api.proxyUrl({a:3}));
  assert.throws(() => api.proxyUrl({},false), /local=true/);
  assert.match(api.proxyUrl({id:'a/b 中文'}), /id=a%2Fb%20%E4%B8%AD%E6%96%87/);
  assert.ok(records.every(r => r.options.cookie === false && r.options.buffer === 2));
  console.log('CatVod shared profile: class/binding/digests + actual local HTTP + strict failures PASS');
}
run().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => server.close());
