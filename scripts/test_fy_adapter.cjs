// Synthetic configuration only; no imported plugin bytes or service endpoints.
'use strict';
const assert = require('node:assert/strict');
const {normalizeConfig, extractFy} = require('../shared/catpaw/drpy-fy-extractor.cjs');
let checks = 0;
const test = (name, fn) => { fn(); checks++; };
const bad = (fn, code = 'guard_artifact_invalid') => assert.throws(fn, e => e.message === code);
function config() {
  const api = 'http://127.0.0.1:9/player/mplayer.php';
  return {origin:'http://127.0.0.1:8', userAgent:'Fixture-UA', parsers:[api,api],
    parserMap:Object.fromEntries(['co','BBA','vwnet','YYNB','JD4K','JD2K','qiyi','bilibili','qq','youku'].map(k => [k,api]))};
}
test('strict complete configuration', () => {
  const c = config(), result = normalizeConfig(c);
  assert.deepEqual(result,c); assert.notEqual(result,c); assert.notEqual(result.parserMap,c.parserMap);
});
test('unknown artifact never executes', () => bad(() => extractFy(Buffer.from('synthetic unknown artifact')), 'guard_artifact_unsupported'));
test('artifact type and size', () => {
  for (const value of [null,'source',Buffer.alloc(0),Buffer.alloc(16*1024*1024+1)]) bad(() => extractFy(value));
});
test('origin must be an HTTP origin without auth or fragment', () => {
  const auth = new URL(config().origin); auth.username='fixture'; auth.password='fixture';
  for (const origin of [auth.href,'file:///tmp/a','javascript:void(0)',config().origin+'/path',config().origin+'?a=1',config().origin+'#a',config().origin+'\n']) {
    bad(() => normalizeConfig({...config(),origin}));
  }
});
test('parser mapping complete and bounded', () => {
  for (const parsers of [null,[],[config().parsers[0]],config().parsers.concat(config().parsers)]) bad(() => normalizeConfig({...config(),parsers}));
  const c = config(); delete c.parserMap.qq; bad(() => normalizeConfig(c));
  c.parserMap.qq=config().parsers[0]; c.parserMap.unknown=c.parserMap.qq; bad(() => normalizeConfig(c));
});
test('parser endpoint shape is fixed', () => {
  for (const api of ['http://127.0.0.1:9/other','http://127.0.0.1:9/player/mplayer.php?q=x','data:text/plain,x']) {
    const c=config(); c.parserMap.co=api; bad(() => normalizeConfig(c));
  }
});
test('header and schema rejection', () => {
  for (const userAgent of ['',null,'x'.repeat(513),'x\r\nOther: y']) bad(() => normalizeConfig({...config(),userAgent}));
  bad(() => normalizeConfig({...config(),execute:'anything'}));
});
console.log('FY data-only checks: '+checks+' passed');
