// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
'use strict';
// The imported plugin is data only: never evaluate its Python, DEX or native code.
const crypto = require('node:crypto');
const {zipMember, unwrapGuard, Dex, MAX} = require('./drpy-guard-extractor.cjs');
const ARTIFACTS = {
  'e7375830bcd065b264239e1f0e7da4c99d75abf71e1b6edf50e225ae8b0f4b7e': 'f68c170d1f12077550eb3ec912e7ae004a57624f314db0e6280a2b1cc319ba5c',
  'da3f3a7afcfcded4d58d9c3a574dfb5cb2ddcc3db4290b7d8b3a7346f9ee8096': '7ae99a034ee2616f0b850ab0c1610d5d4d45d627677fa3e41c8e9809bd4b2a8d'
};
const PYTHON = 'cb2ac6239c973bd105be36643d68b1e72d6b8e8c85f29dd8b2428685a4b9de89';
const fail = () => { throw Error('guard_artifact_invalid'); };
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
function endpoint(value) {
  if (typeof value !== 'string' || !value || value.length > 2048 || /[\s\x00-\x1f\x7f\\]/.test(value)) fail();
  let url; try { url = new URL(value); } catch (_) { fail(); }
  if (!['http:', 'https:'].includes(url.protocol) || !url.hostname || url.username || url.password || url.hash) fail();
  return url;
}
function normalizeConfig(config) {
  if (!config || typeof config !== 'object' || Array.isArray(config) ||
      Object.keys(config).sort().join(',') !== 'origin,parserMap,parsers,userAgent') fail();
  const origin = endpoint(config.origin);
  if (origin.pathname !== '/' || origin.search || typeof config.userAgent !== 'string' ||
      !config.userAgent || config.userAgent.length > 512 || /[\r\n\0]/.test(config.userAgent)) fail();
  if (!Array.isArray(config.parsers) || config.parsers.length !== 2 ||
      !config.parserMap || typeof config.parserMap !== 'object' || Array.isArray(config.parserMap)) fail();
  const keys = ['co', 'BBA', 'vwnet', 'YYNB', 'JD4K', 'JD2K', 'qiyi', 'bilibili', 'qq', 'youku'];
  if (Object.keys(config.parserMap).sort().join(',') !== keys.sort().join(',')) fail();
  const parser = value => {
    const url = endpoint(value);
    if (url.pathname !== '/player/mplayer.php' || url.search) fail();
    return url.href;
  };
  return {origin:origin.origin, userAgent:config.userAgent,
    parsers:config.parsers.map(parser),
    parserMap:Object.fromEntries(keys.map(key => [key, parser(config.parserMap[key])]))};
}
function extractFy(bytes) {
  if (!Buffer.isBuffer(bytes) || !bytes.length || bytes.length > MAX) fail();
  const initHash = ARTIFACTS[sha(bytes)];
  if (!initHash) throw Error('guard_artifact_unsupported');
  const budget = {bytes:0, entries:0};
  const dex = new Dex(zipMember(unwrapGuard(zipMember(bytes, 'assets/ftyshinidie.guard', budget)), 'classes.dex', budget));
  const source = dex.reviewedLiteral('Lcom/github/catvod/spider/Fy;', 'init',
    initHash, 7);
  if (sha(source) !== PYTHON) fail();
  // These exact literal shapes belong to the reviewed source hash above. Do not
  // generalize them into an evaluator or guess endpoints in an unknown version.
  const one = expression => { const matches = Array.from(source.matchAll(expression)); if (matches.length !== 1) fail(); return matches[0][1]; };
  const origin = one(/^        self\.host = "([^"\r\n]+)"$/gm);
  const userAgent = one(/^            "User-Agent": "([^"\r\n]+)",$/gm);
  const mapping = one(/^            player_config_map = \{([\s\S]*?)^            \}/gm);
  const parserMap = Object.create(null);
  const entries = Array.from(mapping.matchAll(/'([A-Za-z0-9]+)':\s*\('1',\s*'([^'\r\n]+)'\),/g));
  if (entries.length !== 10) fail();
  for (const [, key, value] of entries) {
    if (Object.prototype.hasOwnProperty.call(parserMap, key)) fail();
    parserMap[key] = endpoint(value).origin + '/player/mplayer.php';
  }
  const fallbacks = one(/^            all_apis = \[([\s\S]*?)^            \]/gm);
  const parsers = Array.from(fallbacks.matchAll(/'([^'\r\n]+)',/g), match => match[1]);
  return normalizeConfig({origin, userAgent, parserMap, parsers});
}
module.exports = {extractFy, normalizeConfig};
