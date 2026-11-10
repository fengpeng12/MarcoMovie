'use strict';
// Owned loopback protocol fixture loaded by the existing embedded Node bridge.
const http = require('node:http');
const fs = require('node:fs');
const crypto = require('node:crypto');
const ready = process.argv[3];
const secret = crypto.randomBytes(16).toString('hex');
let origin, count = 0;
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  if (req.method !== 'GET' || !url.pathname.startsWith('/' + secret + '/')) {
    res.writeHead(404).end(); return;
  }
  count++;
  const path = url.pathname.slice(secret.length + 1);
  if (path === '/search' && url.searchParams.get('q') === 'redirect-fixture') {
    res.writeHead(302, {Location: 'https://example.invalid/never-requested'}).end(); return;
  }
  let value;
  if (path === '/ping') value = { runtime: process.version, count, q: url.searchParams.get('q') };
  else if (path === '/catalog') value = { class: [{ type_id: 'film', type_name: '电影' }],
    list: [{ vod_id: 'opaque/$#?中文', vod_name: '本机示例' }], page: Number(url.searchParams.get('page') || 1), pagecount: 2 };
  else if (path === '/search') value = { list: [{ vod_id: 'opaque/$#?中文', vod_name: url.searchParams.get('q') }] };
  else if (path === '/detail') value = { list: [{ vod_id: url.searchParams.get('id'), vod_name: '本机示例',
    vod_play_from: 'local', vod_play_url: '第一集$episode-1' }] };
  else if (path === '/play') value = { parse: 0, url: origin + '/media.m3u8', episode: url.searchParams.get('episode') };
  else if (path === '/binary') {
    const data = Buffer.from([0, 255, 128, 13, 10, 65]);
    res.writeHead(206, { 'Content-Type': 'application/octet-stream', 'X-Fixture': 'bytes', 'Content-Length': data.length });
    res.end(data); return;
  } else if (path === '/media.m3u8') {
    res.writeHead(200, { 'Content-Type': 'application/vnd.apple.mpegurl' });
    res.end('#EXTM3U\n#EXT-X-ENDLIST\n'); return;
  } else { res.writeHead(404).end(); return; }
  const data = Buffer.from(JSON.stringify(value));
  res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': data.length });
  res.end(data);
});
server.listen(0, '127.0.0.1', () => {
  origin = 'http://127.0.0.1:' + server.address().port + '/' + secret;
  fs.writeFileSync(ready, JSON.stringify({ origin, runtime: process.version }));
});
