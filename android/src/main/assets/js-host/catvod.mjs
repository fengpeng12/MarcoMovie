// App-owned, bounded CatVod profile. Unsupported host features are not exported.
import CryptoJS from 'marco:catvod-crypto';

const bridge = globalThis.__movieCatvodBridge;
if (!bridge || typeof bridge.request !== 'function' || typeof bridge.proxyUrl !== 'function' ||
    typeof bridge.siteKey !== 'string' || !bridge.siteKey)
  throw new Error('CatVod host bridge is unavailable');
const request = bridge.request.bind(bridge);
const proxy = bridge.proxyUrl.bind(bridge);
const sourceKey = bridge.siteKey;
const MAX_BYTES = 6 * 1024 * 1024;
const OPTIONS = new Set(['method', 'headers', 'params', 'body', 'data', 'postType',
  'buffer', 'redirect', 'timeout', 'callTimeout', 'cookie']);
const FORBIDDEN_HEADERS = new Set(['host', 'content-length', 'connection',
  'transfer-encoding', 'upgrade', 'trailer', 'te', 'proxy-connection']);

function object(value, label) {
  if (!value || Object.prototype.toString.call(value) !== '[object Object]' ||
      Object.getOwnPropertySymbols(value).length) throw new TypeError(label + ' requires an object');
  return value;
}
function scalar(value, label) {
  if (!['string', 'boolean', 'number'].includes(typeof value) ||
      typeof value === 'number' && !Number.isFinite(value))
    throw new TypeError(label + ' requires finite scalar values');
  return String(value);
}
function integer(value, min, max, label) {
  if (!Number.isSafeInteger(value) || value < min || value > max) throw new RangeError('Invalid ' + label);
  return value;
}
function jsonValue(value) {
  const text = JSON.stringify(value, (_, item) => {
    if (item && typeof item.then === 'function') throw new TypeError('Await asynchronous JSON values');
    return item;
  });
  if (text === undefined) throw new TypeError('Value must be JSON');
  return text;
}
function charset(contentType) {
  const match = /(?:^|;)\s*charset\s*=\s*["']?([^;"'\s]+)/i.exec(contentType || '');
  return match ? match[1].toLowerCase() : 'utf-8';
}
function encodeText(text, encoding = 'utf-8') {
  if (encoding === 'utf-8' || encoding === 'utf8') return CryptoJS.enc.Utf8.parse(text);
  if (encoding === 'us-ascii' || encoding === 'ascii') {
    if (/[^\x00-\x7f]/.test(text)) throw new TypeError('Text is not ASCII');
    return CryptoJS.enc.Latin1.parse(text);
  }
  if (encoding === 'iso-8859-1' || encoding === 'latin1') {
    if (/[^\x00-\xff]/.test(text)) throw new TypeError('Text is not Latin-1');
    return CryptoJS.enc.Latin1.parse(text);
  }
  throw new Error('Unsupported CatVod text charset: ' + encoding);
}
function decodeText(words, encoding) {
  if (encoding === 'utf-8' || encoding === 'utf8') return CryptoJS.enc.Utf8.stringify(words);
  if (encoding === 'iso-8859-1' || encoding === 'latin1') return CryptoJS.enc.Latin1.stringify(words);
  if (encoding === 'us-ascii' || encoding === 'ascii') {
    const result = CryptoJS.enc.Latin1.stringify(words);
    if (/[^\x00-\x7f]/.test(result)) throw new TypeError('Response is not ASCII');
    return result;
  }
  throw new Error('Unsupported CatVod text charset: ' + encoding);
}
function byteWords(bytes) {
  if (bytes.length > MAX_BYTES) throw new RangeError('CatVod body exceeds 6 MiB');
  const words = [];
  for (let i = 0; i < bytes.length; i++) {
    integer(bytes[i], 0, 255, 'body byte');
    words[i >>> 2] = (words[i >>> 2] || 0) | bytes[i] << (24 - i % 4 * 8);
  }
  return CryptoJS.lib.WordArray.create(words, bytes.length);
}
function normalize(url, options) {
  if (typeof url !== 'string' || !/^https?:\/\/[^/?#\s]+/i.test(url) || /[\x00-\x20\x7f]/.test(url))
    throw new TypeError('CatVod requests require an HTTP(S) URL');
  options = object(options ?? {}, 'Request options');
  for (const key of Object.keys(options)) if (!OPTIONS.has(key)) throw new Error('Unsupported CatVod option: ' + key);
  if ('cookie' in options && options.cookie !== false) throw new Error('CatVod Cookie integration is not supported');
  const headers = Object.create(null);
  if (options.headers != null) {
    for (const [key, value] of Object.entries(object(options.headers, 'Headers'))) {
      if (!/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(key) || typeof value !== 'string' || /[\r\n\x00]/.test(value))
        throw new TypeError('Invalid CatVod header');
      const lower = key.toLowerCase();
      if (FORBIDDEN_HEADERS.has(lower)) throw new Error('Unsupported CatVod transport header: ' + key);
      if (lower in headers) throw new TypeError('Duplicate CatVod header');
      headers[lower] = value;
    }
    if (jsonValue(headers).length > 32768) throw new RangeError('CatVod headers exceed limit');
  }
  if (options.params != null) {
    const pairs = [];
    for (const [key, value] of Object.entries(object(options.params, 'Query parameters'))) {
      for (const item of Array.isArray(value) ? value : [value]) {
        if (item == null) continue;
        pairs.push(encodeURIComponent(key) + '=' + encodeURIComponent(scalar(item, 'Query')));
      }
    }
    url = url.split('#', 1)[0];
    if (pairs.length) url += (url.includes('?') ? '&' : '?') + pairs.join('&');
  }
  let method = options.method == null || options.method === '' ? 'GET' : options.method;
  if (typeof method !== 'string') throw new TypeError('Invalid CatVod method');
  method = method.toUpperCase();
  if (method === 'HEADER') method = 'HEAD';
  if (!['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'].includes(method))
    throw new Error('Unsupported CatVod method');
  const buffer = integer(options.buffer ?? 0, 0, 3, 'buffer');
  const redirect = integer(options.redirect ?? 1, 0, 1, 'redirect');
  const timeout = integer(options.timeout ?? 10000, 1, 2147483647, 'timeout');
  const transport = {method, headers, buffer: 2, redirect, timeout, cookie: false};
  if ('callTimeout' in options) transport.callTimeout = integer(options.callTimeout, 1, 2147483647, 'callTimeout (unbounded calls are unsupported)');
  if ('body' in options && 'data' in options) throw new TypeError('data and body are mutually exclusive');
  const raw = options.body != null, data = Object.prototype.hasOwnProperty.call(options, 'data');
  if ((method === 'GET' || method === 'HEAD') && (raw || data)) throw new TypeError('Method does not accept a body');
  const postType = options.postType == null || options.postType === '' ? 'json' : options.postType;
  if (postType !== 'json' && postType !== 'form') throw new Error('Unsupported CatVod postType');
  let words;
  if (raw) {
    if (!headers['content-type']) throw new TypeError('Raw body requires Content-Type');
    if (typeof options.body === 'string') words = encodeText(options.body, charset(headers['content-type']));
    else if (Array.isArray(options.body)) words = byteWords(options.body);
    else throw new TypeError('Raw body must be text or a byte array');
  } else if (data) {
    if (postType === 'json') {
      words = encodeText(jsonValue(options.data));
      headers['content-type'] = 'application/json; charset=utf-8';
    } else {
      const pairs = Object.entries(object(options.data, 'Form data')).map(([key, value]) =>
        encodeURIComponent(key) + '=' + encodeURIComponent(scalar(value, 'Form').trim()));
      words = encodeText(pairs.join('&'));
      headers['content-type'] = 'application/x-www-form-urlencoded';
    }
  } else if (['POST', 'PUT', 'PATCH'].includes(method)) words = byteWords([]);
  if (words) {
    if (words.sigBytes > MAX_BYTES) throw new RangeError('CatVod body exceeds 6 MiB');
    transport.bodyBase64 = CryptoJS.enc.Base64.stringify(words);
  }
  return {url, transport, buffer};
}
async function req(url, options = {}) {
  try {
    const normalized = normalize(url, options);
    const result = await request(normalized.url, normalized.transport);
    if (!result || !Number.isInteger(result.code) || result.code < 100 || result.code > 599 ||
        typeof result.content !== 'string') throw new Error('Invalid CatVod transport response');
    const headers = object(result.headers, 'Response headers');
    let contentType = '';
    for (const [key, value] of Object.entries(headers)) {
      if (typeof value !== 'string' || /[\r\n\x00]/.test(key + value)) throw new TypeError('Invalid response header');
      if (key.toLowerCase() === 'content-type') contentType = value;
    }
    if (result.content.length > Math.ceil(MAX_BYTES / 3) * 4 || result.content.length % 4 ||
        !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(result.content))
      throw new Error('Invalid CatVod binary response');
    const words = CryptoJS.enc.Base64.parse(result.content);
    if (words.sigBytes > MAX_BYTES || CryptoJS.enc.Base64.stringify(words) !== result.content)
      throw new Error('Invalid CatVod binary response');
    let content;
    if (normalized.buffer === 2) content = result.content;
    else if (normalized.buffer === 0) content = decodeText(words, charset(contentType));
    else {
      const bytes = new Uint8Array(words.sigBytes);
      for (let i = 0; i < bytes.length; i++) bytes[i] = words.words[i >>> 2] >>> (24 - i % 4 * 8) & 255;
      content = normalized.buffer === 3 ? bytes.buffer : Array.from(bytes);
    }
    return {...result, headers, content};
  } catch (error) {
    // Match official req's failure object; json below turns it into an exception.
    return {code: '', headers: {}, content: '', error: `${error?.name || 'Error'}: ${error?.message || String(error)}`};
  }
}
async function json(url, options = {}) {
  if (options?.buffer) throw new TypeError('JSON requests require text content');
  const result = await req(url, options);
  if (result.error) throw new Error(result.error);
  if (result.code < 200 || result.code >= 300) throw new Error('HTTP ' + result.code);
  return JSON.parse(result.content);
}
export const net = Object.freeze({req, json});
export function proxyUrl(params = {}, local = true) {
  if (local !== true) throw new Error('CatVod proxy only supports local=true');
  params = object(params ?? {}, 'Proxy parameters');
  const values = Object.create(null);
  for (const [key, value] of Object.entries(params)) {
    if (key === 'do' || key === 'siteKey') throw new TypeError('Proxy parameters cannot override routing');
    if (typeof value !== 'string') throw new TypeError('Proxy parameters require string values');
    values[key] = value;
  }
  return proxy(values);
}
export function page(items, pg, limit, total) {
  if (!Array.isArray(items)) throw new TypeError('Page items require an array');
  pg = Math.max(1, Number(pg));
  integer(pg, 1, Number.MAX_SAFE_INTEGER, 'page');
  integer(limit, 1, Number.MAX_SAFE_INTEGER, 'page limit');
  if (total == null) { total = items.length; items = items.slice((pg - 1) * limit, pg * limit); }
  integer(total, 0, Number.MAX_SAFE_INTEGER, 'page total');
  return {list: items, page: pg, pagecount: Math.max(1, Math.ceil(total / limit)), limit, total};
}
export function md5X(text) {
  if (typeof text !== 'string') throw new TypeError('Digest input requires text');
  return CryptoJS.MD5(text).toString();
}
export function sha256X(text) {
  if (typeof text !== 'string') throw new TypeError('Digest input requires text');
  return CryptoJS.SHA256(text).toString();
}
export class Spider {
  constructor() {
    Object.defineProperty(this, 'siteKey', {value: sourceKey, enumerable: true});
    this.net = net;
    const names = new Set(['constructor', ...Object.getOwnPropertyNames(this)]);
    for (let prototype = Object.getPrototypeOf(this); prototype && prototype !== Object.prototype;
        prototype = Object.getPrototypeOf(prototype)) {
      for (const name of Object.getOwnPropertyNames(prototype)) {
        if (names.has(name)) continue;
        names.add(name);
        const method = Object.getOwnPropertyDescriptor(prototype, name).value;
        if (typeof method === 'function') Object.defineProperty(this, name,
          {value: method.bind(this), writable: true, configurable: true});
      }
    }
  }
  init(extend) {}
  homeContent(filter) { return {class: []}; }
  homeVideoContent() { return {list: []}; }
  categoryContent(tid, pg, filter, extend) { return {list: []}; }
  detailContent(ids) { return {list: []}; }
  searchContent(key, quick, pg = '1') { return {list: []}; }
  playerContent(flag, id, vipFlags) { return {}; }
  proxy(params) { return [404, 'text/plain', '']; }
  destroy() {}
  proxyUrl(params = {}, local = true) { return proxyUrl(params, local); }
  page(items, pg, limit, total) { return page(items, pg, limit, total); }
  log(message) { console.log(message); }
}
