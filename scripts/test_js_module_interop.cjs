// Exercise the exact shared loader shipped to Android and Flutter, without Node APIs inside source modules.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const runtime = vm.createContext({});
vm.runInContext(fs.readFileSync(path.join(__dirname, '../android/src/main/assets/js-host/module-interop.js'), 'utf8'), runtime);
vm.runInContext(String.raw`
const modules = {
 'main.js': "const data=require('./data.json'); const a=require('./a.js'); module.exports={home(){return data},detail(id){return {id, cycle:a.cycle}},play(flag,id){return {url:id,flag}}};",
 'data.json': '{"list":[{"vod_id":"fixture"}]}',
 'a.js': "exports.name='a';exports.cycle=require('./b.js').parent;",
 'b.js': "exports.parent=require('./a.js').name;"
};
globalThis.spider = __movieSelectSpider(__movieLoadCommonJS('main.js', (name) => {
 name=name.replace(/^\.\//,''); if(!modules[name])throw new Error('missing dependency');
 return {name,source:modules[name]};
}));
`, runtime);
assert.equal(vm.runInContext('spider.home().list[0].vod_id', runtime), 'fixture');
assert.equal(vm.runInContext("spider.detail('42').cycle", runtime), 'a');
assert.equal(vm.runInContext("spider.detail('42').id", runtime), '42');
assert.equal(vm.runInContext("spider.play('Main','https://media.example/clip.mp4').url", runtime), 'https://media.example/clip.mp4');
assert.equal(vm.runInContext("__movieSelectSpider({default:spider})===spider", runtime), true);
assert.throws(() => vm.runInContext('__movieSelectSpider(null)', runtime), /no Spider export/);
assert.throws(() => vm.runInContext("__movieLoadCommonJS('bad.js', () => ({name:'bad.js',source:'module.exports = ;'}))", runtime), /Unexpected token/);
console.log('PASS shared CommonJS JSON/cycle/home/detail/play/default/error boundaries');

// This checks the shipped settlement protocol; JNI job pumping has a separate Android probe.
(async () => {
  vm.runInContext(String.raw`
globalThis.constructed = 0;
class FullSpider {
  #state;
  constructor() { constructed++; this.#state = {count:0}; }
  init(ext) { this.#state.ext=ext; }
  homeContent(filter) { this.#state.count++; return {filter,ext:this.#state.ext,count:this.#state.count}; }
  homeVideoContent() { return 'raw-string'; }
  categoryContent(id,pg,filter,extend) { return {id,pg,filter,extend}; }
  detailContent(ids) { return {ids,count:this.#state.count}; }
  async searchContent(word,quick,pg) { return {word,quick,pg}; }
  playerContent(flag,id,vip) { return {flag,id,vip}; }
  proxy(params) { return [200,'text/plain',this.#state.ext,params]; }
}
globalThis.full = __movieSelectSpider({default:FullSpider}, {rawExtension:'  { "fixture": 1 }\n'});
full.init({fixture:1});
`, runtime);
  const inspect = expression => JSON.parse(vm.runInContext(`JSON.stringify(${expression})`, runtime));
  assert.deepEqual(inspect('full.home(true)'), {filter:true,ext:'  { "fixture": 1 }\n',count:1});
  assert.equal(vm.runInContext('constructed', runtime), 1);
  assert.equal(vm.runInContext('full.homeVod()', runtime), 'raw-string');
  assert.deepEqual(inspect("full.category('opaque',3,true,{year:'2025'})"), {id:'opaque',pg:'3',filter:true,extend:{year:'2025'}});
  assert.deepEqual(inspect("full.detail('x$y#z')"), {ids:['x$y#z'],count:1});
  assert.deepEqual(inspect("full.detail(['a','a'])"), {ids:['a','a'],count:1});
  assert.deepEqual(inspect('full.detail([])'), {ids:[],count:1});
  assert.deepEqual(JSON.parse(JSON.stringify(await vm.runInContext("full.search('word',false)",runtime))), {word:'word',quick:false,pg:'1'});
  assert.deepEqual(inspect("full.play('line','opaque',['vip'])"), {flag:'line',id:'opaque',vip:['vip']});
  assert.equal(vm.runInContext('full.proxy({}).length', runtime), 4);
  vm.runInContext(String.raw`
globalThis.fullObject = Object.freeze({homeContent(){return this.state},state:{value:'bound'},init(ext){this.state.ext=ext}});
globalThis.wrapped = __movieSelectSpider(fullObject, {rawExtension:null});
wrapped.init({value:1});
globalThis.mixed = __movieSelectSpider({init(ext){this.ext=ext},home(){return this.ext},homeContent(){throw Error('short method must win')},detailContent(ids){return ids}}, {rawExtension:'not legacy init'});
mixed.init({legacy:true});
globalThis.cat = __movieSelectSpider({init(ext){this.ext=ext},homeContent(){return this.ext},detailContent(ids){return ids}},{preserveInit:true,rawExtension:'not cat init'});
cat.init({stype:3,skey:'fixture',ext:{value:1}});
globalThis.asyncError = __movieSelectSpider({homeContent(){return Promise.reject(new Error('full method rejection'))}});
`, runtime);
  assert.deepEqual(inspect('wrapped.home()'), {value:'bound',ext:'{"value":1}'});
  assert.equal(vm.runInContext('Object.hasOwn(fullObject,"home")',runtime), false);
  assert.deepEqual(inspect('mixed.home()'), {legacy:true});
  assert.deepEqual(inspect("mixed.detail('a')"), ['a']);
  assert.deepEqual(inspect('cat.home()'), {stype:3,skey:'fixture',ext:{value:1}});
  assert.deepEqual(inspect("cat.detail(['a'])"), ['a']);
  assert.equal(vm.runInContext('typeof wrapped.play',runtime), 'undefined');
  vm.runInContext("globalThis.shortClass=__movieSelectSpider(class {#value=0;home(){return ++this.#value}detail(id){return id}})",runtime);
  assert.equal(vm.runInContext('shortClass.home()',runtime),1);
  assert.equal(vm.runInContext('shortClass.home()',runtime),2);
  assert.equal(vm.runInContext("shortClass.detail('scalar')",runtime),'scalar');
  vm.runInContext("globalThis.fieldClass=__movieSelectSpider(class {#value=0;homeContent=()=>++this.#value})",runtime);
  assert.equal(vm.runInContext('fieldClass.home()',runtime),1);
  assert.equal(vm.runInContext('fieldClass.home()',runtime),2);
  vm.runInContext(`globalThis.liveOnly = __movieSelectSpider(class {
    #ext; init(ext){this.#ext=ext} liveContent(url){return {url,ext:this.#ext}}
  }, {rawExtension:'  {"live":true}  '});liveOnly.init({live:true});`,runtime);
  assert.deepEqual(inspect("liveOnly.liveContent('opaque')"), {url:'opaque',ext:'  {"live":true}  '});
  await assert.rejects(vm.runInContext('asyncError.home()', runtime), /full method rejection/);
  assert.throws(() => vm.runInContext('__movieSelectSpider(class {constructor(){return Promise.resolve({})} homeContent(){}})',runtime), /synchronous/);
  console.log('PASS full Spider aliases/class/private-state/raw-extension/mixed-short/cat/array/Promise boundaries');

  vm.runInContext("__movieBeginCall(async()=>{await Promise.resolve();return {list:[{vod_id:'async'}]}})", runtime);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(JSON.parse(vm.runInContext('__movieFinishCall()', runtime)).list[0].vod_id, 'async');
  vm.runInContext("__movieBeginCall(async()=>{throw new Error('fixture rejection')})", runtime);
  await new Promise(resolve => setImmediate(resolve));
  assert.throws(() => vm.runInContext('__movieFinishCall()', runtime), /fixture rejection/);
  vm.runInContext('__movieBeginCall(()=>new Promise(()=>{}))', runtime);
  assert.throws(() => vm.runInContext('__movieFinishCall()', runtime), /did not settle/);
  vm.runInContext("__movieBeginCall(()=>{throw new Error('sync failure')})", runtime);
  assert.throws(() => vm.runInContext('__movieFinishCall()', runtime), /sync failure/);
  vm.runInContext('__movieBeginCall(()=>{const v={};v.self=v;return v})', runtime);
  assert.throws(() => vm.runInContext('__movieFinishCall()', runtime), /circular/i);
  vm.runInContext('__movieBeginCall(()=>({ok:true}))', runtime);
  assert.equal(JSON.parse(vm.runInContext('__movieFinishCall()', runtime)).ok, true);
  console.log('PASS shared Promise settlement/rejection/pending/serialization/recovery boundaries');
})().catch(error => { console.error(error); process.exitCode = 1; });
