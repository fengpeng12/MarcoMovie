// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
'use strict';
const {normalizeConfig} = require('./drpy-fy-extractor.cjs');

function installFy() {
  var cache = Object.create(null), challenge = null;
  var cookies = local.get('fy-v1', 'cookies') || [];
  if (!Array.isArray(cookies)) cookies = [];
  var categories = [
    ['/label/qq', '腾讯VIP精选'], ['/label/bli', 'B站VIP精选'], ['/label/youku', '优酷VIP精选'],
    ['5', '短剧'], ['2', '电视剧'], ['1', '电影'], ['4', '动漫'], ['3', '综艺']
  ];
  function fail(code) { unsupportedFeature(code || 'drpy_source_unavailable'); }
  function text(value) { return value == null ? '' : String(value); }
  function url(value, base) {
    if (typeof value !== 'string' || !value || value.length > 8192 || /[\x00-\x20\x7f\\]/.test(value)) fail('drpy_media_protocol');
    var result = joinUrl(base || cfg.origin + '/', value);
    var match = /^(https?):\/\/([^/?#@]+)([^?#]*)(?:[?#]|$)/i.exec(result);
    if (!match) fail('drpy_media_protocol');
    return {value:result, origin:match[1].toLowerCase() + '://' + match[2].toLowerCase(),
      host:match[2].toLowerCase().replace(/:\d+$/, ''), path:match[3] || '/', secure:match[1] === 'https'};
  }
  function header(headers, name) {
    var key = Object.keys(headers || {}).find(function (key) { return key.toLowerCase() === name; });
    return key ? text(headers[key]) : '';
  }
  function validCookie(c) {
    return c && typeof c.owner === 'string' && /^https?:\/\/[^/?#@\s]+$/.test(c.owner) && typeof c.secure === 'boolean' &&
      typeof c.name === 'string' && /^[!#$%&'*+.^_`|~0-9a-z-]+$/i.test(c.name) &&
      typeof c.value === 'string' && c.value.length <= 8192 && !/[\x00-\x20\x7f;,]/.test(c.value) &&
      typeof c.path === 'string' && c.path.startsWith('/') && c.path.length <= 8192 && !/[\x00-\x1f\x7f]/.test(c.path) &&
      (c.expires === null || (typeof c.expires === 'number' && Number.isFinite(c.expires) && c.expires > Date.now()));
  }
  function receiveCookies(target, headers) {
    var before = JSON.stringify(cookies);
    cookies = cookies.filter(validCookie);
    // SourceHttp preserves separate Set-Cookie fields as newline-separated
    // values. Also handle combined headers without splitting an Expires date.
    var fields = header(headers, 'set-cookie').split(/\r?\n|,(?=\s*[^;,=\s]+\s*=)/);
    fields.forEach(function (field) {
      var parts = field.split(';'), first = parts.shift(), equal = first.indexOf('=');
      if (equal < 1) return;
      var c = {owner:target.origin, name:first.slice(0, equal).trim(), value:first.slice(equal + 1).trim(),
        path:target.path.slice(0, target.path.lastIndexOf('/')) || '/', secure:false, expires:null};
      var domain = '', maxAge = null;
      parts.forEach(function (part) {
        var pair = part.trim().split('='), key = pair.shift().toLowerCase(), value = pair.join('=').trim();
        if (key === 'domain') domain = value.replace(/^\./, '').toLowerCase();
        if (key === 'path' && value.startsWith('/')) c.path = value;
        if (key === 'secure') c.secure = true;
        if (key === 'max-age' && /^-?\d+$/.test(value)) maxAge = Number(value);
        if (key === 'expires') { var date = Date.parse(value); if (Number.isFinite(date)) c.expires = date; }
      });
      // Cookies never cross an origin, including the site's independent parse
      // services. Do not propagate broad Domain cookies to another source.
      if (domain && domain !== target.host && !target.host.endsWith('.' + domain)) return;
      if (c.secure && !target.secure) return;
      if (maxAge !== null) c.expires = maxAge <= 0 ? 0 : Date.now() + Math.min(maxAge, 31536000) * 1000;
      if (!/^[!#$%&'*+.^_`|~0-9a-z-]+$/i.test(c.name) || /[\x00-\x20\x7f;,]/.test(c.value) || c.value.length > 8192) return;
      cookies = cookies.filter(function (old) { return old.owner !== c.owner || old.path !== c.path || old.name !== c.name; });
      if (validCookie(c)) cookies.push(c);
    });
    cookies = cookies.slice(-64);
    if (JSON.stringify(cookies).length > 96 * 1024) fail('drpy_storage_limit');
    if (JSON.stringify(cookies) !== before) local.set('fy-v1', 'cookies', cookies);
  }
  function send(address, options) {
    var target = url(address), opts = options || {};
    var headers = Object.assign({'User-Agent':cfg.userAgent, Accept:'text/html,application/json,*/*', 'Accept-Language':'zh-CN,zh;q=0.9'}, opts.headers || {});
    var active = cookies.filter(function (c) {
      return validCookie(c) && c.owner === target.origin && (!c.secure || target.secure) &&
        (target.path === c.path || target.path.startsWith(c.path.endsWith('/') ? c.path : c.path + '/'));
    }).sort(function (a, b) { return b.path.length - a.path.length; });
    if (active.length) headers.Cookie = active.map(function (c) { return c.name + '=' + c.value; }).join('; ');
    var response;
    var requestOptions = Object.assign({}, opts, {headers:headers, timeout:8000, redirect:0});
    delete requestOptions.redirected;
    try { response = req(target.value, requestOptions); }
    catch (_) { fail(); }
    if (!response || typeof response.content !== 'string') fail();
    receiveCookies(target, response.headers);
    // Follow only a bounded, explicitly scoped redirect; never carry a Cookie
    // header through a cross-origin redirect or turn POST into another method.
    if ([301, 302, 303, 307, 308].includes(response.code)) {
      if (opts.redirected || opts.method === 'POST') fail();
      var location = header(response.headers, 'location'), next = url(location, target.value);
      if (next.origin !== target.origin) fail();
      return send(next.value, Object.assign({}, opts, {redirected:true}));
    }
    if (response.code < 200 || response.code >= 300) fail();
    return response;
  }
  function verification(html) {
    // A normal page may contain a login captcha or mention verification in its
    // synopsis. Treat those as content when the requested catalogue is present.
    if (/(?:public-list-exp|search-box|slide-info-title|player_aaaa\s*=)/.test(html)) return false;
    return /(?:系统安全验证|SafeLineChallenge|Checking your browser)/i.test(html) ||
      (/(?:captcha\.php|name\s*=\s*["'](?:check|verify)["'])/i.test(html) && /(?:验证码|人机验证)/.test(html));
  }
  function get(address) {
    var target = url(address), html = send(target.value).content;
    if (verification(html)) {
      local.set('fy-v1', 'verificationReferer', target.origin === cfg.origin ? target.value : cfg.origin + '/');
      fail('drpy_verification_required');
    }
    return html;
  }
  function soup(html) { return DRPYDeps.cheerio.load(html, {xml:{xmlMode:false, decodeEntities:true}}, false); }
  function joined(selection) {
    var result = [], stack = selection.toArray().reverse();
    while (stack.length) {
      var node = stack.pop();
      if (node.type === 'text') { var content = node.data.trim(); if (content) result.push(content); }
      else if (!['comment', 'script', 'style'].includes(node.type)) {
        var children = node.children || [];
        for (var i = children.length - 1; i >= 0; i--) stack.push(children[i]);
      }
    }
    return result.join(' ');
  }
  function picture(value) {
    if (!value) return '';
    var previous = globalThis.__drpyUnsupported;
    try { return url(value.replace(/&amp;/g, '&')).value; }
    catch (_) { globalThis.__drpyUnsupported = previous; return ''; }
  }
  function catalogue(html, search) {
    var $ = soup(html), seen = Object.create(null), result = [];
    var rows = search ? $('.search-box') : $('a.public-list-exp');
    if (search && !rows.length) rows = $('.public-list-box');
    rows.each(function (_, node) {
      var row = $(node), a = search ? row.find('.thumb-txt a').first() : row;
      if (search && !a.length) a = row.find('a').first();
      var match = /\/detail\/(\d+)\.html/.exec(a.attr('href') || '');
      if (!match || seen[match[1]]) return;
      seen[match[1]] = true;
      var image = search ? row.find('.left img').first() : row.find('img').first();
      if (!image.length) image = row.find('img').first();
      var title = a.attr('title') || (search ? a.text().trim() : image.attr('alt')) || '';
      var remark = row.find(search ? '.public-list-prb' : '.ft2').first();
      if (!remark.length) remark = row.find(search ? '.ft2' : '.public-list-prb').first();
      var video = {vod_id:match[1], vod_name:title.trim() || '未知影片',
        vod_pic:picture(image.attr('data-src') || (search ? image.attr('src') : '') || ''), vod_remarks:remark.text().trim()};
      if (!search) video.vod_year = row.find('.public-prt').eq(1).text().trim();
      result.push(video);
    });
    return result;
  }
  function options(names, first) { return [{n:'全部', v:first || ''}].concat(names.split('|').filter(Boolean).map(function (name) { return {n:name, v:name}; })); }
  var years = [{n:'全部', v:''}]; for (var year = 2026; year > 2003; year--) years.push({n:String(year), v:String(year)});
  var common = {
    area:options('大陆|香港|台湾|美国|韩国|日本|泰国|新加坡|马来西亚|印度|英国|法国|加拿大|西班牙|俄罗斯|其它'),
    year:years, lang:options('国语|英语|粤语|闽南语|韩语|日语|法语|德语|其它'),
    letter:options('ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('').join('|') + '|0-9'),
    orderBy:[{n:'时间',v:'time'}, {n:'人气',v:'hits'}, {n:'评分',v:'score'}]
  };
  var genres = {
    '2':'古装|战争|青春偶像|喜剧|家庭|犯罪|动作|奇幻|剧情|历史|经典|乡村|情景|商战|网剧|其他',
    '1':'喜剧|爱情|恐怖|动作|科幻|剧情|战争|警匪|犯罪|动画|奇幻|武侠|冒险|枪战|悬疑|惊悚|经典|青春|文艺|微电影|古装|历史|运动|农村|儿童|网络电影',
    '4':'情感|科幻|热血|推理|搞笑|冒险|奇幻|战斗|校园|萝莉|治愈|原创|亲子|益智|励志|其他',
    '3':'选秀|情感|访谈|播报|音乐|美食|旅游|搞笑|游戏|亲子|其它'
  };
  var types = {'2':[['国产剧','13'],['日韩剧','15'],['海外剧','16']],
    '1':[['动作片','6'],['喜剧片','7'],['恐怖片','8'],['科幻片','9'],['爱情片','10'],['剧情片','11']],
    '4':[['国产动漫','25'],['日韩动漫','26']], '3':[['大陆综艺','21'],['日韩综艺','22']]};
  var filters = {}, labels = {type:'类型', class:'剧情', area:'地区', year:'年份', lang:'语言', letter:'字母', orderBy:'排序'};
  Object.keys(types).forEach(function (id) {
    var values = Object.assign({type:[{n:'全部',v:id}].concat(types[id].map(function (v) {return {n:v[0],v:v[1]};})), class:options(genres[id])}, common);
    filters[id] = Object.keys(values).map(function (key) {return {key:key,name:labels[key],value:values[key]};});
  });
  filters['5'] = ['year','letter'].map(function (key) {return {key:key,name:labels[key],value:common[key]};});
  __drpy.home = function () { return {class:categories.map(function (c) {return {type_id:c[0],type_name:c[1]};}), filters:filters}; };
  __drpy.homeVod = function () { return {list:catalogue(get(cfg.origin + '/'), false)}; };
  __drpy.category = function (id, page, filter, extend) {
    if (!categories.some(function (c) {return c[0] === id;})) fail('drpy_unsupported_category');
    var selected = extend || {}, fields = Object.create(null);
    (filters[id] || []).forEach(function (item) {fields[item.key] = item.value;});
    Object.keys(selected).forEach(function (key) {
      if (!Array.isArray(fields[key]) || !fields[key].some(function (v) {return v.v === text(selected[key]);})) fail('drpy_unsupported_filter');
    });
    var address = id.startsWith('/label') ? id + '/page/' + page + '.html' :
      '/cupfox-list/' + [selected.type || id,selected.area || '','',selected.class || '',selected.lang || '',selected.letter || '',selected.orderBy || '','',page,'','',selected.year || ''].map(function (v) {return encodeURIComponent(v);}).join('-') + '.html';
    var html = get(url(address).value), values = catalogue(html, false), match = /\d+\/(\d+)页/.exec(html);
    var last = id.startsWith('/label') ? (values.length < 24 ? page : page + 2) : (match ? Number(match[1]) : page);
    return {list:values,page:page,pagecount:Math.max(page,last),limit:id.startsWith('/label') ? 24 : 36,total:last * (id.startsWith('/label') ? 24 : 36)};
  };
  __drpy.search = function (word, quick, page) {
    if (page >= 2) return {list:[],page:page,pagecount:1,limit:36,total:0};
    try { word = decodeURIComponent(word); } catch (_) {}
    var values = catalogue(get(cfg.origin + '/cupfox-search/-------------.html?wd=' + encodeURIComponent(word)), true);
    return {list:values,page:page,pagecount:1,limit:36,total:values.length};
  };
  __drpy.detail = function (value) {
    var id = text(value).split(',')[0].trim(); if (!/^\d+$/.test(id)) fail('drpy_invalid_id');
    var $ = soup(get(cfg.origin + '/detail/' + id + '.html')), lines = [], playlists = [], used = {};
    var tabs = $('.anthology-tab .swiper-slide:not(.swiper-slide-duplicate)');
    if (!tabs.length) tabs = $('.anthology-tab .swiper-slide');
    tabs.each(function (_, node) {
      var item = $(node), name = joined(item).replace(/[#\s]+/g, ' ').trim(), source = /^(\d+)\s*\//.exec(item.attr('aria-label') || '');
      if (name && name.length < 20) lines.push({name:name, source:source ? source[1] : null});
    });
    if (!lines.length) lines.push({name:'默认线路',source:null});
    $('.anthology-list-box').each(function (_, node) {
      var episodes = [], source = null;
      $(node).find('a').each(function (_, link) {
        var a = $(link), name = a.text().trim(), match = /\/play\/(.*?)\.html/.exec(a.attr('href') || '');
        if (name && match) { episodes.push(name + '$' + match[1]); if (source === null) source = match[1].split('-')[1] || null; }
      });
      if (episodes.length) playlists.push({source:source,episodes:episodes.reverse()});
    });
    var names = [], values = [], seen = {};
    lines.forEach(function (line, index) {
      var selected = line.source ? playlists.findIndex(function (list, i) {return !used[i] && list.source === line.source;}) : -1;
      if (selected < 0) selected = index < playlists.length && !used[index] ? index : playlists.findIndex(function (_, i) {return !used[i];});
      var episodes = selected < 0 ? [] : playlists[selected].episodes;
      if (selected >= 0) used[selected] = true;
      var key = JSON.stringify([line.name, episodes.length]);
      if (!seen[key]) {seen[key] = true; names.push(line.name); values.push(episodes.join('#'));}
    });
    var info = $('.detail-info .slide-info');
    return {list:[{vod_id:id, vod_name:$('h3.slide-info-title').first().text().trim(), vod_pic:picture($('img.lazy').first().attr('data-src') || ''),
      vod_actor:info.eq(2).text().replace(/演员：\s*/g,'').trim(), vod_remarks:info.eq(4).text().replace(/连载\s*:\s*/g,'').trim(),
      vod_content:joined($('#height_limit').first()), vod_play_from:names.join('$$$'),vod_play_url:values.join('$$$')}]};
  };
  function playerData(html) {
    var match = /(?:var\s+)?player_aaaa\s*=\s*/.exec(html); if (!match) fail('drpy_media_unresolved');
    var start = match.index + match[0].length, depth = 0, quoted = false, escaped = false, end = -1;
    if (html[start] !== '{') fail('drpy_media_unresolved');
    for (var i = start; i < Math.min(html.length, start + 65536); i++) {
      var c = html[i];
      if (quoted) { if (escaped) escaped = false; else if (c === '\\') escaped = true; else if (c === '"') quoted = false; }
      else if (c === '"') quoted = true;
      else if (c === '{') depth++;
      else if (c === '}' && --depth === 0) {end = i + 1; break;}
    }
    if (end < 0) fail('drpy_media_unresolved');
    var source = html.slice(start,end), result;
    try {result = JSON.parse(source);} catch (_) {
      try {result = JSON.parse(source.replace(/([{,]\s*)([A-Za-z0-9_]+)\s*:/g,'$1"$2":'));} catch (_) {fail('drpy_media_unresolved');}
    }
    if (!result || typeof result.url !== 'string' || !result.url || result.url.length > 8192) fail('drpy_media_unresolved');
    return result;
  }
  function parseMedia(media, api) {
    var target = url(api), page = send(target.origin + '/player/?url=' + encodeURIComponent(media), {headers:{Referer:cfg.origin + '/'}}).content;
    var token = /data-te=["']([^"']+)["']/.exec(page) || /data-token=["']([^"']+)["']/.exec(page) ||
      /\btoken["']?\s*[:=]\s*["']([^"']+)/.exec(page);
    if (!token || token[1].length > 2048) return null;
    var content = send(api, {method:'POST',data:'url=' + encodeURIComponent(media) + '&token=' + encodeURIComponent(token[1]),
      headers:{'Content-Type':'application/x-www-form-urlencoded; charset=UTF-8', Referer:target.origin + '/player/', 'X-Requested-With':'XMLHttpRequest'}}).content;
    var resolved;
    try {var value = JSON.parse(content); resolved = value.url || (typeof value.data === 'string' ? value.data : value.data && value.data.url);} catch (_) {
      var match = /https?:\/\/[^\s"'<>]+\.(?:m3u8|mp4)[^\s"'<>]*/.exec(content); resolved = match ? match[0] : '';
    }
    return typeof resolved === 'string' && resolved ? url(resolved).value : null;
  }
  __drpy.play = function (flag, id) {
    var key = JSON.stringify([flag,id]), old = cache[key];
    if (old && old.until > Date.now()) return old.value;
    if (!/^\d+(?:-\d+){2}$/.test(id) && !/^https?:\/\//i.test(id)) fail('drpy_invalid_id');
    var data = playerData(get(/^https?:\/\//i.test(id) ? id : cfg.origin + '/play/' + id + '.html')), media = '';
    if (/^https?:\/\//i.test(data.url) && /\.(?:m3u8|mp4)$/i.test(url(data.url).path)) media = url(data.url).value;
    else {
      var primary = cfg.parserMap[data.from] || cfg.parsers[/4k|jd/i.test(flag) ? 1 : 0];
      var candidates = [primary].concat(cfg.parsers.filter(function (api) {return api !== primary;}));
      for (var i = 0; i < candidates.length && !media; i++) {
        // An individual parse service failure must not fabricate a media URL.
        try {media = parseMedia(data.url, candidates[i]);} catch (error) {
          if (globalThis.__drpyUnsupported === 'drpy_verification_required') throw error;
          globalThis.__drpyUnsupported = null;
        }
      }
    }
    if (!media) fail('drpy_media_unresolved');
    var result = {parse:0,url:media,header:{'User-Agent':cfg.userAgent}};
    if (Object.keys(cache).length >= 128) delete cache[Object.keys(cache)[0]];
    cache[key] = {value:result,until:Date.now()+300000}; return result;
  };
  // Explicit, user-operated image verification. No remote OCR or native process.
  __drpy.action = function (raw) {
    var input; try {input = JSON.parse(raw);} catch (_) {fail('drpy_action_invalid');}
    if (!input || input.type !== 'verification') fail('drpy_action_invalid');
    if (input.operation === 'challenge') {
      var referer = local.get('fy-v1', 'verificationReferer') || cfg.origin + '/';
      if (url(referer).origin !== cfg.origin) fail('drpy_action_invalid');
      var image = send(cfg.origin + '/captcha.php?type=code&r=' + Date.now(), {buffer:2,headers:{Referer:referer}});
      var mime = header(image.headers,'content-type').split(';')[0].trim().toLowerCase();
      if (!['image/png','image/jpeg','image/webp','image/gif'].includes(mime) || image.content.length > 350000 || !/^[A-Za-z0-9+/]+={0,2}$/.test(image.content)) fail('drpy_verification_unavailable');
      challenge = {id:Date.now().toString(36) + Math.random().toString(36).slice(2),referer:referer,until:Date.now()+180000};
      return {type:'image',id:challenge.id,mime:mime,imageBase64:image.content};
    }
    if (input.operation === 'submit') {
      if (!challenge || challenge.id !== input.id || challenge.until < Date.now() || typeof input.code !== 'string' || !/^[A-Za-z0-9]{4,6}$/.test(input.code)) fail('drpy_action_invalid');
      var response = send(cfg.origin + '/captcha.php?type=verify', {method:'POST',data:'check=' + encodeURIComponent(input.code),
        headers:{'Content-Type':'application/x-www-form-urlencoded; charset=UTF-8',Referer:challenge.referer,Origin:cfg.origin,'x-requested-with':'com.hiker.youtoo'}}).content;
      var ok = /验证成功/.test(response); try {ok = ok || JSON.parse(response).code === 1;} catch (_) {}
      if (ok) {challenge = null; local.delete('fy-v1','verificationReferer');}
      return {verified:ok};
    }
    fail('drpy_action_invalid');
  };
}
module.exports = function fyRule(config) {
  const cfg = normalizeConfig(config);
  return 'var cfg=' + JSON.stringify(cfg) + ';\nvar rule={title:"FY",host:cfg.origin,homeUrl:"/",searchable:2,quickSearch:1,filterable:1,timeout:8000,预处理:"js:rule._install();",_install:' + installFy.toString() + '};';
};
