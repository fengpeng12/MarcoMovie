// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
'use strict';
const { normalizeConfig } = require('./drpy-t4-extractor.cjs');
// Only this generated source's isolated worker gets these CMS ABI methods.
// Using a closure avoids the archived HTML core rewriting IDs and pagination.
function installT4() {
  var cache = null;
  function fail(code) { unsupportedFeature(code || 'drpy_source_unavailable'); }
  function object(v) { return v && typeof v === 'object' && !Array.isArray(v); }
  function address(value, base) {
    if (typeof value !== 'string' || !value || /[\x00-\x20\x7f\\]/.test(value)) fail('drpy_media_protocol');
    var url; try { url = joinUrl(base || cfg.api, value); } catch (_) { fail('drpy_media_protocol'); }
    var match = /^(https?):\/\/([^/?#]+)([^#]*)$/i.exec(url);
    if (!match || match[2].indexOf('@') !== -1) fail('drpy_media_protocol');
    return { url: url, origin: match[1].toLowerCase() + '://' + match[2].toLowerCase() };
  }
  function query(base, params) {
    var separator = base.indexOf('?'), prefix = separator < 0 ? base : base.slice(0, separator);
    var pairs = (separator < 0 ? '' : base.slice(separator + 1)).split('&').filter(Boolean);
    pairs = pairs.filter(function (pair) {
      var key; try { key = decodeURIComponent(pair.split('=')[0].replace(/\+/g, ' ')); } catch (_) { fail(); }
      return !Object.prototype.hasOwnProperty.call(params, key);
    });
    Object.keys(params).forEach(function (key) { pairs.push(encodeURIComponent(key) + '=' + encodeURIComponent(String(params[key]))); });
    return prefix + (pairs.length ? '?' + pairs.join('&') : '');
  }
  function get(url, json) {
    address(url);
    var response;
    try { response = req(url, { headers: { 'User-Agent': cfg.userAgent, Accept: 'application/json,text/html,*/*' } }); }
    catch (_) { fail(); }
    var body = response && response.content;
    if (typeof body !== 'string') fail();
    if (/(?:SafeLineChallenge|__cdn_pow|Checking your browser|系统安全验证|正在验证您的浏览器|人机验证|verify you are human)/i.test(body) || /<input[^>]+(?:name|id)=["']?(?:verify|validate|captcha)/i.test(body)) fail('drpy_verification_required');
    if (response.code < 200 || response.code >= 300) fail();
    if (!json) return body;
    var value; try { value = JSON.parse(body); } catch (_) { fail(); }
    if (!object(value) || value.error || (Object.prototype.hasOwnProperty.call(value, 'code') && ![1, 200, '1', '200', true].includes(value.code))) fail();
    return value;
  }
  function text(value) { return value === undefined || value === null ? '' : String(value); }
  function safePicture(value) {
    if (!value) return '';
    try {
      var url = joinUrl(cfg.api, String(value));
      return /^https?:\/\/[^/?#@]+(?:[/?#]|$)/i.test(url) && !/[\x00-\x20\x7f\\]/.test(url) ? url : '';
    } catch (_) { return ''; }
  }
  function vod(value, detail) {
    if (!object(value) || value.vod_id === undefined || value.vod_id === null || !text(value.vod_name)) fail();
    var result = Object.assign(Object.create(null), value, { vod_id: text(value.vod_id), vod_name: text(value.vod_name), vod_pic: safePicture(value.vod_pic) });
    if (detail) {
      result.vod_content = pdfh('<div>' + text(value.vod_content || value.vod_blurb) + '</div>', 'div&&Text');
      // Keep the legacy episode separators and opaque IDs intact. HTTP addresses
      // are normalized only when a selected episode is resolved by play().
      result.vod_play_from = text(value.vod_play_from);
      result.vod_play_url = text(value.vod_play_url);
    }
    return result;
  }
  function list(doc, detail) {
    if (!Array.isArray(doc.list)) fail();
    return doc.list.map(function (item) { return vod(item, detail); });
  }
  function number(value, fallback) {
    if (typeof value !== 'number' && (typeof value !== 'string' || !/^\d+$/.test(value))) return fallback;
    var n = Number(value); return Number.isSafeInteger(n) && n >= 0 && n <= 1000000000 ? n : fallback;
  }
  function page(doc, current, values) {
    return { page: number(doc.page, current), pagecount: number(doc.pagecount, current), limit: number(doc.limit, values.length), total: number(doc.total, values.length), list: values };
  }
  function headers(value) {
    if (typeof value === 'string') { try { value = JSON.parse(value); } catch (_) { fail('drpy_media_unresolved'); } }
    if (value === undefined || value === null) return { 'User-Agent': cfg.userAgent };
    if (!object(value) || Object.keys(value).length > 64) fail('drpy_media_unresolved');
    var result = {};
    Object.keys(value).forEach(function (key) {
      if (!/^[!#$%&'*+.^_`|~0-9a-z-]+$/i.test(key) || typeof value[key] !== 'string' || value[key].length > 8192 || /[\r\n\0]/.test(value[key])) fail('drpy_media_unresolved');
      if (!/^(host|connection|content-length|transfer-encoding)$/i.test(key)) result[key] = value[key];
    });
    // These headers are explicitly returned by the selected playback endpoint.
    // Imported implicit credentials remain owned by the host's same-origin rule.
    return result;
  }
  __drpy.home = function () {
    var doc = get(query(cfg.api, cfg.type === 4 ? { filter: 'true' } : {}), true);
    if (!Array.isArray(doc.class)) fail();
    var seen = Object.create(null), classes = doc.class.filter(function (item) {
      if (!object(item) || item.type_id === undefined || !text(item.type_name)) fail();
      var id = text(item.type_id), name = text(item.type_name);
      if (seen[id] || (cfg.categories !== null && cfg.categories.indexOf(name) < 0) || (cfg.excludedCategories !== null && cfg.excludedCategories.indexOf(name) >= 0)) return false;
      seen[id] = true; return true;
    }).map(function (item) { return Object.assign({}, item, { type_id: text(item.type_id), type_name: text(item.type_name) }); });
    var recommended = cfg.type === 1 ? get(query(cfg.api, { ac: 'detail' }), true) : doc;
    cache = { at: Date.now(), list: list(recommended, false) };
    // T4's original category request never forwards extend filters. Do not show
    // server filter metadata as working controls without a supported contract.
    return { class: classes, filters: {}, list: cache.list };
  };
  __drpy.homeVod = function () {
    if (!cache || Date.now() - cache.at > 30000) __drpy.home(false);
    return { list: cache.list };
  };
  __drpy.category = function (id, pg, filter, extend) {
    Object.keys(extend || {}).forEach(function (key) { var v = extend[key]; if (v !== undefined && v !== null && text(v).trim() !== '' && text(v).trim() !== '全部') fail('drpy_filter_not_supported'); });
    var doc = get(query(cfg.api, { ac: 'detail', t: id, pg: pg }), true);
    return page(doc, pg, list(doc, false));
  };
  __drpy.detail = function (id) {
    var doc = get(query(cfg.api, { ac: 'detail', ids: id }), true);
    return { list: list(doc, true) };
  };
  __drpy.search = function (word, quick, pg) {
    var doc;
    if (cfg.searchBase) {
      var html = get(cfg.searchBase + 'index.php/vod/search/page/' + pg + '/wd/' + encodeURIComponent(word) + '.html', false);
      var ids = [], seen = Object.create(null);
      pdfa(html, 'a[href*="index.php/vod/detail"]').forEach(function (a) {
        var href = pdfh(a, 'a&&href'), match = /(?:^|\/)id\/([^/?#]+)\.html(?:[?#]|$)/.exec(href);
        if (!match || pdfh(a, 'a&&Text').indexOf(word) < 0) return;
        var id; try { id = decodeURIComponent(match[1]); } catch (_) { fail(); }
        if (!seen[id]) { seen[id] = true; ids.push(id); }
      });
      if (!ids.length) {
        // A known empty-search page is a valid empty result; an unrelated HTML
        // error/login page is not evidence that no matching title exists.
        if (!/(?:暂无相关|没有找到|未找到|搜索结果|搜索到|无相关)/.test(pdfh(html, 'body&&Text'))) fail();
        return { page: pg, pagecount: pg, limit: 0, total: 0, list: [] };
      }
      if (ids.length > 200) fail();
      doc = get(query(cfg.api, { ac: 'detail', ids: ids.join(',') }), true);
    } else doc = get(query(cfg.api, { ac: 'detail', wd: word, pg: pg }), true);
    var values = list(doc, false).filter(function (item) { return item.vod_name.indexOf(word) >= 0; });
    return page(doc, pg, values);
  };
  __drpy.play = function (flag, id) {
    var doc;
    if (cfg.type === 4) doc = get(query(cfg.api, { play: id, flag: flag }), true);
    else if (cfg.playUrl) doc = get(cfg.playUrl + id, true);
    else return { parse: 0, url: address(id).url, header: { 'User-Agent': cfg.userAgent } };
    if (typeof doc.url !== 'string' || !doc.url) fail('drpy_media_unresolved');
    var result = Object.assign({}, doc, { url: address(doc.url).url, header: headers(doc.header === undefined ? doc.headers : doc.header) });
    result.parse = doc.parse === undefined ? 0 : Number(doc.parse);
    if (![0, 1].includes(result.parse)) fail('drpy_media_unresolved');
    delete result.headers;
    return result;
  };
}
module.exports = function t4Rule(config) {
  if (!config || typeof config !== 'object' || typeof config.userAgent !== 'string' || !config.userAgent || /[\r\n\0]/.test(config.userAgent) || config.userAgent.length > 8192) throw Error('guard_artifact_invalid');
  const normalized = normalizeConfig({ siteUrl: config.api, type: config.type,
    ...(config.categories === null ? {} : { categories: config.categories }),
    ...(config.excludedCategories === null ? {} : { rmCategories: config.excludedCategories }),
    ...(config.searchBase ? { searchMode: 'web&' + config.searchBase } : {}),
    ...(config.playUrl ? { playUrl: config.playUrl } : {}) });
  if (config.origin !== normalized.origin) throw Error('guard_artifact_invalid');
  normalized.userAgent = config.userAgent;
  return 'var cfg=' + JSON.stringify(normalized) + ';\nvar rule={title:"T4",host:cfg.origin,homeUrl:cfg.api,searchable:2,quickSearch:1,filterable:0,timeout:8000,预处理:"js:rule._install();",_install:' + installT4.toString() + '};';
};
