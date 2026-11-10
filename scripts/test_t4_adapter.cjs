// Public synthetic data only. No imported plugin, site, key or binary.
'use strict';
const assert = require('node:assert/strict');
const x = require('../shared/catpaw/drpy-t4-extractor.cjs');
let checks=0;
function test(name,fn){fn();checks++;}
function bad(fn,code='guard_artifact_invalid'){assert.throws(fn,e=>e.message===code);}
const key=Buffer.from('fixture-key');
const encrypted="ojCooVbjn2xw63uL/qpmj7ryRo2aYBx0y6XRJowW2GQKhPVJLfMJ+gzAtApjoSJ7JwsofN3eHMjeCdSFAM4WowaRKf/LfnLtzciF6OJ4529gD1ZGyDFVSjkyEizY2gviKSjWPIISXeuM495qu4AjfaA/UA/jUg==";
test('RFC 6229 RC4 test vector',()=>assert.equal(x.rc4(Buffer.alloc(16),Buffer.from('0102030405','hex')).toString('hex'),'b2396305f03dc027ccc3524a0a1118a8'));
test('fixed independent UTF8 Chinese configuration',()=>{const c=x.decodeT4Ext(encrypted,key);assert.equal(c.api,'http://127.0.0.1:9/cms?token=fixture');assert.deepEqual(c.categories,['电影','剧集']);assert.deepEqual(c.excludedCategories,['排除']);assert.equal(c.type,1);assert.equal(c.searchBase,'');});
test('wrong key rejected',()=>bad(()=>x.decodeT4Ext(encrypted,Buffer.from('wrong'))));
test('invalid Base64 and limits',()=>{for(const value of ['',encrypted+'=',encrypted.replace(/=/g,'')+'!', 'A'.repeat(16388),'{}',null,[]])bad(()=>x.decodeT4Ext(value,key));});
test('invalid UTF8 rejected',()=>bad(()=>x.decodeT4Ext(x.rc4(Buffer.from([255]),key).toString('base64'),key)));
test('unknown artifact rejected without native loading',()=>bad(()=>x.extractT4(Buffer.alloc(64),'AAAA'),'guard_artifact_unsupported'));
test('invalid caller buffer',()=>bad(()=>x.extractT4('fixture','AAAA')));
function config(change={}){return {siteUrl:'http://127.0.0.1:9/cms',type:1,...change};}
test('default type4 and category absence',()=>{const c=x.normalizeConfig({siteUrl:config().siteUrl});assert.equal(c.type,4);assert.equal(c.categories,null);});
test('empty category array remains explicit',()=>assert.deepEqual(x.normalizeConfig(config({categories:[]})).categories,[]));
test('foreign executable/credential endpoints rejected',()=>{for(const url of ['file:///tmp/config','javascript:void(0)','http://name:secret@127.0.0.1/cms','http://127.0.0.1/cms#secret','http://127.0.0.1/\n'])bad(()=>x.normalizeConfig(config({siteUrl:url})));});
test('unknown configuration fields and type rejected',()=>{bad(()=>x.normalizeConfig(config({execute:'anything'})));bad(()=>x.normalizeConfig(config({type:2})));bad(()=>x.normalizeConfig(config({categories:'film'})));});
test('web search and parse prefix preservation',()=>{const c=x.normalizeConfig(config({searchMode:'web&http://127.0.0.1:9/web/',playUrl:'http://127.0.0.1:9/parse?url='}));assert.equal(c.searchBase,'http://127.0.0.1:9/web/');assert.equal(c.playUrl,'http://127.0.0.1:9/parse?url=');});
test('unknown/malformed search modes rejected',()=>{for(const value of ['api','web&file:///tmp/','web&http://127.0.0.1:9/web','web&http://127.0.0.1:9/?token=x'])bad(()=>x.normalizeConfig(config({searchMode:value})));});
function elf(two=false){const b=Buffer.alloc(320);Buffer.from([127,69,76,70,2,1,1]).copy(b);b.writeUInt16LE(183,18);b.writeBigUInt64LE(64n,32);b.writeUInt16LE(64,52);b.writeUInt16LE(56,54);b.writeUInt16LE(two?2:1,56);for(let i=0;i<(two?2:1);i++){let p=64+56*i;b.writeUInt32LE(1,p);b.writeBigUInt64LE(256n,p+8);b.writeBigUInt64LE(4096n,p+16);b.writeBigUInt64LE(32n,p+32);b.writeBigUInt64LE(64n,p+40);}Buffer.from('0123456789abcdef').copy(b,256);return b;}
test('ELF VA to file mapping',()=>assert.equal(x.elfBytes(elf(),4100,4).toString(),'4567'));
test('ELF zero-filled memory is not file-backed data',()=>bad(()=>x.elfBytes(elf(),4130,4)));
test('ELF ambiguous segment mappings rejected',()=>bad(()=>x.elfBytes(elf(true),4100,4)));
test('ELF integer bounds rejected',()=>{for(const address of [-1,NaN,Number.MAX_SAFE_INTEGER])bad(()=>x.elfBytes(elf(),address,4));bad(()=>x.elfBytes(elf(),4100,0));});
test('ELF architecture and table bounds rejected',()=>{let b=elf();b.writeUInt16LE(62,18);bad(()=>x.elfBytes(b,4100,4));b=elf();b.writeBigUInt64LE(1000000n,32);bad(()=>x.elfBytes(b,4100,4));});
console.log('T4 data-only checks: '+checks+' passed');
