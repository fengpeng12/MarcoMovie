// Fixed-library compilation must preserve source overrides, state and deadlines.
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const {execFileSync} = require('node:child_process');
const root = path.join(__dirname, '../android/src/main/assets/python-host');
const generated = fs.readFileSync(path.join(root, 'compiled-modules.js'));
assert.deepEqual(execFileSync(process.execPath, [path.join(__dirname, 'compile_python_modules.cjs')]), generated);
console.log('PASS fixed libraries reproduce exactly with the pinned interpreter');

function context(compiled) {
  const runtime = vm.createContext({installPythonPrecompiled(){}, setTimeout, clearTimeout});
  for (const name of ['skulpt.min.js','skulpt-stdlib.js',...(compiled?['compiled-modules.js']:[]),
    'html.js','regex.js','json.js','io.js','spider.js']) {
    vm.runInContext(fs.readFileSync(path.join(root, name),'utf8'), runtime, {filename:name});
  }
  const calls = [], compile = runtime.Sk.compile;
  runtime.Sk.compile = function(source, name, ...args) { calls.push(name); return compile(source,name,...args); };
  return {runtime,calls};
}

(async()=>{
  const script = `import requests, json
class Spider:
 def init(self,ext): self.session=requests.Session()
 def homeContent(self,filter):
  before=self.session.cookies.get('state','fresh')
  self.session.cookies.set('state','kept')
  return [before, json.dumps({'z':'中文','a':9007199254740993123456789},sort_keys=True,ensure_ascii=False,separators=(',',':'))]
`;
  for (const compiled of [false,true]) {
    const {runtime,calls}=context(compiled);
    const host=runtime.createPythonSpider(script);
    await host.init('');
    assert.deepEqual(JSON.parse(JSON.stringify(await host.home(true))),['fresh','{"a":9007199254740993123456789,"z":"中文"}']);
    assert.equal((await host.home(true))[0],'kept');
    for (const name of ['src/lib/requests/__init__.py','src/lib/json/__init__.py']) {
      assert.equal(calls.includes(name), !compiled, name);
    }
    assert(calls.includes('<source>.py'));
    assert.equal(runtime.Sk.execLimit,8000);
    if (compiled) {
      const requests=runtime.Sk.sysmodules.mp$subscript(new runtime.Sk.builtin.str('requests'));
      runtime.Sk.execStart=Date.now()-9000;
      assert.throws(()=>runtime.Sk.misceval.callsimArray(requests.$d.CaseInsensitiveDict,
        [runtime.Sk.ffi.remapToPy({owned:'value'})]), error => error.toString().includes('TimeLimitError'));
    }
  }
  console.log('PASS compiled and source modules agree; user script compilation and 8-second module deadline retained');
  for(let repeat=0;repeat<2;repeat++) {
    const {runtime,calls}=context(true);
    const host=runtime.createPythonSpider("import requests\nclass Spider:\n def homeContent(self,f): return requests.MARK\n",
      {'requests/__init__.py':"MARK='owned override'\n"});
    await host.init('');assert.equal(await host.home(true),'owned override');
    assert(calls.includes('src/lib/requests/__init__.py'));
  }
  console.log('PASS imported overrides are not replaced by compiled app libraries');
  const fresh=context(true).runtime.createPythonSpider(script);
  await fresh.init('');assert.equal((await fresh.home(true))[0],'fresh');
  console.log('PASS generated code does not share mutable source state');
})().catch(error=>{console.error(error);process.exitCode=1;});
