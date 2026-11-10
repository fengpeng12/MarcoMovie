// Same ES-module fixture is imported by real iOS QuickJS and Node18 --jitless.
// The paired bridge is deliberately synthetic; these are not socket tests.
import {Spider, net, proxyUrl, page, md5X, sha256X} from 'catvod';

const origin = 'https://fixture.invalid/catvod';
let constructed = 0, latest;
class NativeSpider extends Spider {
  #calls = 0;
  #raw;
  constructor() { super(); constructed++; latest = this; }
  init(ext) { this.#raw = ext; }
  homeContent(filter) { return {raw: this.#raw, filter, calls: ++this.#calls}; }
  homeVideoContent() { return {raw: this.#raw, calls: ++this.#calls}; }
  categoryContent(tid, pg, filter, extend) { return {tid, pg, filter, extend, calls: ++this.#calls}; }
  searchContent(wd, quick, pg) { return {wd, quick, pg, calls: ++this.#calls}; }
  detailContent(ids) { return {ids, calls: ++this.#calls}; }
  playerContent(flag, id, vip) { return {flag, id, vip, raw: this.#raw, calls: ++this.#calls}; }
}

let assertions = 0;
function assert(value, message) { assertions++; if (!value) throw Error(message); }
function equal(actual, expected, message) { assert(JSON.stringify(actual) === JSON.stringify(expected), message); }
async function rejects(call, pattern, message) {
  try { await call(); } catch (error) { assert(pattern.test(String(error)), message + ': ' + error); return; }
  assert(false, message + ': did not throw');
}

const groups = [
  ['quickjs_catvod_class_lifecycle', async () => {
    const raw = ' \n { "title" : "本机配置" } \t';
    const selected = __movieSelectSpider({default: NativeSpider}, {rawExtension: raw});
    await selected.init({normalized: 'must not replace raw ext'});
    const detached = latest.homeContent;
    equal(detached(false), {raw, filter: false, calls: 1}, 'detached inherited binding/private state');
    equal(await selected.home(true), {raw, filter: true, calls: 2}, 'home/raw ext');
    equal(await selected.homeVod(), {raw, calls: 3}, 'homeVideoContent same instance');
    equal(await selected.category('film', 2, true, {type: 'dzp'}),
      {tid: 'film', pg: '2', filter: true, extend: {type: 'dzp'}, calls: 4}, 'category string page');
    equal(await selected.search('中文', false, 3), {wd: '中文', quick: false, pg: '3', calls: 5}, 'search string page');
    equal(await selected.detail('opaque/$#?中文'), {ids: ['opaque/$#?中文'], calls: 6}, 'detail array mapping');
    equal(await selected.play('line', 'episode', ['vip']), {flag: 'line', id: 'episode', vip: ['vip'], raw, calls: 7}, 'player same state');
    assert(constructed === 1 && latest.siteKey === 'owned-ios-catvod-source' && latest.net === net, 'one instance and source bridge');
  }],
  ['quickjs_catvod_query_unicode', async () => {
    const value = await net.json(origin + '/echo?old=1#unused', {params: {q: ['中文', 'a b'], skip: null, flag: true}});
    equal(value.url, origin + '/echo?old=1&q=%E4%B8%AD%E6%96%87&q=a%20b&flag=true', 'duplicate Unicode query');
    equal({method: value.method, buffer: value.buffer, redirect: value.redirect, timeout: value.timeout, cookie: value.cookie},
      {method: 'GET', buffer: 2, redirect: 1, timeout: 10000, cookie: false}, 'normalized bridge defaults');
  }],
  ['quickjs_catvod_json_form', async () => {
    const json = await net.json(origin + '/echo', {method: 'post', data: {word: '中文', items: [1, true]}, headers: {'X-Owned': 'yes'}});
    equal(json.bodyBase64, 'eyJ3b3JkIjoi5Lit5paHIiwiaXRlbXMiOlsxLHRydWVdfQ==', 'JSON exact UTF-8 bytes');
    assert(json.method === 'POST' && json.headers['content-type'] === 'application/json; charset=utf-8' && json.headers['x-owned'] === 'yes', 'JSON headers/method');
    const form = await net.json(origin + '/echo', {method: 'POST', postType: 'form', data: {word: ' 中 文 ', num: 2}});
    equal(form.bodyBase64, 'd29yZD0lRTQlQjglQUQlMjAlRTYlOTYlODcmbnVtPTI=', 'form trim/escaping');
    assert(form.headers['content-type'] === 'application/x-www-form-urlencoded', 'form content type');
  }],
  ['quickjs_catvod_raw_request_bytes', async () => {
    const raw = await net.json(origin + '/echo', {method: 'POST', headers: {'Content-Type': 'application/octet-stream'}, body: [0, 255, 128, 65], redirect: 0, timeout: 321, callTimeout: 654});
    equal(raw.bodyBase64, 'AP+AQQ==', 'binary body must not use text coercion');
    assert(raw.redirect === 0 && raw.timeout === 321 && raw.callTimeout === 654 && !('data' in raw) && !('body' in raw), 'transport options/no duplicate body');
    const empty = await net.json(origin + '/echo', {method: 'PUT'});
    equal(empty.bodyBase64, '', 'empty raw body is preserved');
  }],
  ['quickjs_catvod_response_buffer_types', async () => {
    const text = await net.req(origin + '/text', {buffer: 0});
    assert(typeof text.content === 'string' && text.content === '中文', 'buffer0 UTF-8 text');
    const array = await net.req(origin + '/bytes', {buffer: 1});
    assert(Array.isArray(array.content), 'buffer1 actual array'); equal(array.content, [0, 255, 128, 65], 'buffer1 bytes');
    const base64 = await net.req(origin + '/bytes', {buffer: 2});
    assert(typeof base64.content === 'string' && base64.content === 'AP+AQQ==', 'buffer2 base64');
    const binary = await net.req(origin + '/bytes', {buffer: 3});
    assert(binary.content instanceof ArrayBuffer && Object.prototype.toString.call(binary.content) === '[object ArrayBuffer]', 'buffer3 actual ArrayBuffer');
    equal(Array.from(new Uint8Array(binary.content)), [0, 255, 128, 65], 'buffer3 exact bytes');
    assert(binary.code === 206 && binary.headers['x-owned'] === 'bytes', 'response status/headers');
  }],
  ['quickjs_catvod_error_contract', async () => {
    const transport = await net.req(origin + '/transport');
    assert(transport.code === '' && transport.content === '' && /owned transport failure/.test(transport.error), 'req transport failure object');
    await rejects(() => net.json(origin + '/transport'), /owned transport failure/, 'json rejects transport');
    await rejects(() => net.json(origin + '/async-transport'), /owned async transport failure/, 'json rejects asynchronous transport');
    const failed = await net.req(origin + '/failed');
    assert(failed.code === 503 && failed.content === 'unavailable' && !failed.error, 'req non2xx remains response');
    await rejects(() => net.json(origin + '/failed'), /HTTP 503/, 'json rejects non2xx');
    await rejects(() => net.json(origin + '/bad-json'), /SyntaxError/, 'json rejects malformed JSON');
    assert(/binary response/.test((await net.req(origin + '/bad-base64')).error), 'invalid binary response rejected');
    assert(/charset/.test((await net.req(origin + '/unsupported-charset')).error), 'unsupported charset explicit');
    for (const options of [{foo: true}, {cookie: true}, {buffer: 4}, {timeout: 0}, {callTimeout: 0},
      {method: 'TRACE'}, {data: {}}, {headers: {'content-length': '4'}},
      {headers: {Foo: 'a', foo: 'b'}}, {method: 'POST', body: [256], headers: {'content-type': 'x'}},
      {method: 'POST', body: [], data: {}}, {params: {q: {nested: true}}}]) {
      const count = __catvodNativeRecords.length;
      assert(Boolean((await net.req(origin + '/echo', options)).error), 'unsupported option must fail');
      assert(__catvodNativeRecords.length === count, 'invalid option must not reach bridge');
    }
  }],
  ['quickjs_catvod_local_proxy', async () => {
    equal(proxyUrl({id: 'a/b 中文'}), 'http://127.0.0.1:18191/_spider/owned/proxy?do=js&siteKey=owned-ios-catvod-source&id=a%2Fb%20%E4%B8%AD%E6%96%87', 'local proxy escaping');
    for (const call of [() => proxyUrl({do: 'other'}), () => proxyUrl({siteKey: 'other'}),
      () => proxyUrl({id: 3}), () => proxyUrl({}, false), () => proxyUrl([])]) {
      const count = __catvodNativeProxyRecords.length;
      await rejects(call, /Proxy|proxy/, 'strict proxy parameters');
      assert(count === __catvodNativeProxyRecords.length, 'invalid proxy parameters must not reach bridge');
    }
  }],
  ['quickjs_catvod_page_crypto', async () => {
    equal(page([1, 2, 3, 4, 5], '2', 2), {list: [3, 4], page: 2, pagecount: 3, limit: 2, total: 5}, 'local page slicing');
    equal(page(['remote-page'], 2, 10, 31), {list: ['remote-page'], page: 2, pagecount: 4, limit: 10, total: 31}, 'remote total does not reslice');
    assert(page([], 1, 5).pagecount === 1, 'empty pagecount');
    await rejects(() => page([], 1, 0), /RangeError/, 'invalid page limit');
    equal(md5X(''), 'd41d8cd98f00b204e9800998ecf8427e', 'empty MD5');
    equal(md5X('中文'), 'a7bac2239fcdcb3a067903d8077c4a07', 'Unicode MD5');
    equal(sha256X(''), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', 'empty SHA256');
    equal(sha256X('中文'), '72726d8818f693066ceb69afa364218b692e62ea92b385782363780f47529c21', 'Unicode SHA256');
    await rejects(() => md5X(7), /TypeError/, 'digest inputs are text only');
  }]
];

export const groupNames = groups.map(([name]) => name);
globalThis.__catvodNativeGroupNames = groupNames;
globalThis.__catvodRunNativeGroup = async function (index) {
  assertions = 0;
  const [name, run] = groups[index];
  try { await run(); return {name, passed: true, assertions}; }
  catch (error) { return {name, passed: false, assertions, error: String(error)}; }
};
