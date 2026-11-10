// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
'use strict';
// Data-only interoperability: no native, DEX, or imported script execution.
const crypto = require('node:crypto');
const { TextDecoder } = require('node:util');
const { zipMember, MAX } = require('./drpy-guard-extractor.cjs');
const PROFILES = {
  'e7375830bcd065b264239e1f0e7da4c99d75abf71e1b6edf50e225ae8b0f4b7e': {
    nativeSha: 'fac9e3937d9928e437ebff79bc5164df418a6adb212494ef21c273579b045dcb',
    mask: 0xb7
  },
  'da3f3a7afcfcded4d58d9c3a574dfb5cb2ddcc3db4290b7d8b3a7346f9ee8096': {
    nativeSha: 'd5d8adee01e1bdc4c18b445e19ce7c94fb296ca6dce6f18a08786504fc961f01',
    mask: 0x15
  }
};
const fail = () => { throw Error('guard_artifact_invalid'); };
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
function bounds(bytes, offset, length) {
  if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length < 0 || offset + length > bytes.length) fail();
}
function elfBytes(bytes, address, length) {
  if (!Buffer.isBuffer(bytes) || bytes.length > MAX || !Number.isSafeInteger(address) || address < 0 || !Number.isSafeInteger(length) || length < 1 || length > 4096) fail();
  bounds(bytes, 0, 64);
  if (!bytes.subarray(0, 7).equals(Buffer.from([127, 69, 76, 70, 2, 1, 1])) || bytes.readUInt16LE(18) !== 183 || bytes.readUInt16LE(52) !== 64) fail();
  const phoff = Number(bytes.readBigUInt64LE(32)), stride = bytes.readUInt16LE(54), count = bytes.readUInt16LE(56);
  if (stride !== 56 || !count || count > 64) fail();
  bounds(bytes, phoff, stride * count);
  const matches = [];
  for (let i = 0; i < count; i++) {
    const p = phoff + i * stride;
    if (bytes.readUInt32LE(p) !== 1) continue;
    const offset = Number(bytes.readBigUInt64LE(p + 8)), va = Number(bytes.readBigUInt64LE(p + 16));
    const size = Number(bytes.readBigUInt64LE(p + 32)), memory = Number(bytes.readBigUInt64LE(p + 40));
    bounds(bytes, offset, size);
    if (!Number.isSafeInteger(va) || !Number.isSafeInteger(memory) || memory < size || !Number.isSafeInteger(va + size)) fail();
    if (va <= address && address + length <= va + size) matches.push(offset + address - va);
  }
  if (matches.length !== 1) fail();
  bounds(bytes, matches[0], length);
  return Buffer.from(bytes.subarray(matches[0], matches[0] + length));
}
function rc4(bytes, key) {
  if (!Buffer.isBuffer(bytes) || !Buffer.isBuffer(key) || !key.length || key.length > 256 || bytes.length > 65536) fail();
  const state = Uint8Array.from({ length: 256 }, (_, i) => i);
  let j = 0;
  for (let i = 0; i < 256; i++) { j = (j + state[i] + key[i % key.length]) & 255; [state[i], state[j]] = [state[j], state[i]]; }
  const result = Buffer.alloc(bytes.length);
  let i = 0; j = 0;
  for (let p = 0; p < bytes.length; p++) { i = (i + 1) & 255; j = (j + state[i]) & 255; [state[i], state[j]] = [state[j], state[i]]; result[p] = bytes[p] ^ state[(state[i] + state[j]) & 255]; }
  return result;
}
function endpoint(value) {
  if (typeof value !== 'string' || !value || value.length > 4096 || /[\x00-\x20\x7f\\]/.test(value)) fail();
  let url; try { url = new URL(value); } catch (_) { fail(); }
  if (!['http:', 'https:'].includes(url.protocol) || !url.hostname || url.username || url.password || url.hash) fail();
  return url;
}
function normalizeConfig(value) {
  const allowed = new Set(['siteUrl', 'type', 'categories', 'rmCategories', 'searchMode', 'playUrl']);
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).some(key => !allowed.has(key))) fail();
  const api = endpoint(value.siteUrl), type = value.type === undefined ? 4 : value.type;
  if (![1, 4].includes(type)) fail();
  const names = key => {
    if (value[key] === undefined) return null;
    if (!Array.isArray(value[key]) || value[key].length > 256 || value[key].some(v => typeof v !== 'string' || !v || v.length > 256 || /[\x00-\x1f\x7f]/.test(v))) fail();
    return [...new Set(value[key])];
  };
  let searchBase = '';
  if (value.searchMode !== undefined && value.searchMode !== '') {
    if (typeof value.searchMode !== 'string' || !value.searchMode.startsWith('web&')) fail();
    const search = endpoint(value.searchMode.slice(4));
    if (search.search || !search.pathname.endsWith('/')) fail();
    searchBase = search.href;
  }
  const playUrl = value.playUrl === undefined || value.playUrl === '' ? '' : endpoint(value.playUrl).href;
  return { origin: api.origin, api: api.href, type, categories: names('categories'), excludedCategories: names('rmCategories'), searchBase, playUrl, userAgent: 'Mozilla/5.0' };
}
function decodeT4Ext(ext, key) {
  if (typeof ext !== 'string' || !ext.length || ext.length > 16384 || ext.length % 4 !== 0 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(ext)) fail();
  const bytes = Buffer.from(ext, 'base64');
  if (bytes.toString('base64') !== ext) fail();
  let shifted; try { shifted = new TextDecoder('utf-8', { fatal: true }).decode(rc4(bytes, key)); } catch (_) { fail(); }
  let plain = '';
  // JNI's decrypted UTF-16 output subtracts two from each uint16, not each byte.
  for (let i = 0; i < shifted.length; i++) plain += String.fromCharCode((shifted.charCodeAt(i) - 2) & 65535);
  let parsed; try { parsed = JSON.parse(plain); } catch (_) { fail(); }
  return normalizeConfig(parsed);
}
function extractT4(bytes, ext) {
  if (!Buffer.isBuffer(bytes) || !bytes.length || bytes.length > MAX) fail();
  const profile = PROFILES[sha(bytes)];
  if (!profile) throw Error('guard_artifact_unsupported');
  const native = zipMember(bytes, 'assets/ftyguard_v8.so');
  if (native.length !== 102440 || sha(native) !== profile.nativeSha) throw Error('guard_artifact_integrity');
  // Reviewed ELF initializer decodes this region with the profile's XOR mask; it is data only.
  const key = elfBytes(native, 0x19198, 13).map(value => value ^ profile.mask);
  return decodeT4Ext(ext, key);
}
module.exports = { extractT4, decodeT4Ext, normalizeConfig, elfBytes, rc4 };
