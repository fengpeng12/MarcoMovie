// The package source and expected values are generated independently by CPython.
// These tests execute only self-authored fixtures; no host filesystem is exposed.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.join(__dirname, '..');
const fixtureRoot = path.join(__dirname, 'fixtures');
const source = fs.readFileSync(path.join(fixtureRoot, 'python_package_contract.py'), 'utf8');
const fixture = JSON.parse(fs.readFileSync(path.join(fixtureRoot, 'python_package_fixture.json'), 'utf8'));
const expected = JSON.parse(fs.readFileSync(path.join(fixtureRoot, 'python_package_expected.json'), 'utf8'));
const plain = value => JSON.parse(JSON.stringify(value));
const base64 = value => Buffer.from(value).toString('base64');
function context() {
  let requests = 0, siblings = 0;
  const runtime = vm.createContext({console, setTimeout, clearTimeout,
    req() { requests++; throw Error('test forbids network requests'); }});
  for (const file of ['skulpt.min.js', 'skulpt-stdlib.js', 'compiled-modules.js', 'json.js', 'io.js', 'spider.js']) {
    vm.runInContext(fs.readFileSync(path.join(root, 'android/src/main/assets/python-host', file), 'utf8'), runtime, {filename:file});
  }
  return {runtime, counts:() => [requests, siblings], sibling() { siblings++; throw Error('test forbids remote imports'); }};
}
async function run(source, data, modules = {}, host = context()) {
  const spider = host.runtime.createPythonSpider(source, modules, host.sibling, data);
  await spider.init('');
  return plain(await spider.home(true));
}
function packageFor(source, content = 'first') {
  return {entry:'bundle/main.py', files:{'bundle/main.py':base64(source), 'bundle/data.txt':base64(content)}};
}
async function main() {
  const host = context();
  assert.equal(Buffer.from(fixture.packageData.files[fixture.packageData.entry], 'base64').toString('utf8'), source);
  const actual = await run(source, fixture.packageData, fixture.modules, host);
  const failures = [];
  for (const key of Object.keys(expected)) {
    try { assert.deepEqual(actual[key], expected[key], key); }
    catch (error) { failures.push({key, actual:actual[key], expected:expected[key]}); }
  }
  if (failures.length) throw Error(JSON.stringify(failures, null, 2));
  assert.deepEqual(host.counts(), [0, 0]);
  console.log('PASS Python package: ' + Object.keys(expected).length + ' CPython oracle cases');

  const boundarySource = `import io
class Spider:
 def homeContent(self, filter):
  result = []
  for filename in ['../../outside', '/etc/passwd', 'https://example.invalid/file', 'C:\\\\private', 'missing', '/__package__/../outside', 'data.txt/../missing', '', 'nul\\x00path']:
   try: open(filename).read(); result.append('unexpected')
   except (ValueError, OSError) as error: result.append(type(error).__name__)
  for mode in ['w', 'a', 'x', 'r+', 'wb', 'ab', 'xb', 'r+b']:
   try: io.open('data.txt', mode); result.append('unexpected')
   except io.UnsupportedOperation: result.append('read-only')
  for action in [lambda: open('data.txt', encoding='latin-1'), lambda: open('data.txt', errors='replace'), lambda: open('data.txt', opener=lambda *args: 1), lambda: open('data.txt').fileno(), lambda: open('data.txt', 'rb').getbuffer(), lambda: open('data.txt', 'rb').readinto(b'x')]:
   try: action(); result.append('unexpected')
   except (NotImplementedError, io.UnsupportedOperation): result.append('unsupported')
  return result
`;
  assert.deepEqual(await run(boundarySource, packageFor(boundarySource)), [
    'PermissionError', 'PermissionError', 'ValueError', 'ValueError', 'FileNotFoundError',
    'PermissionError', 'FileNotFoundError', 'ValueError', 'ValueError',
    ...Array(8).fill('read-only'), ...Array(6).fill('unsupported')]);
  console.log('PASS Python package path isolation and explicit read-only/unsupported errors');

  const simple = `class Spider:
 def homeContent(self, filter): return [__file__, open('data.txt').read()]
`;
  const isolated = context();
  assert.deepEqual(await run(simple, packageFor(simple, 'A'), {}, isolated), ['/__package__/bundle/main.py', 'A']);
  const compiler = isolated.runtime.Sk.__movieOriginalCompile;
  assert.deepEqual(await run(simple, packageFor(simple, 'B'), {}, isolated), ['/__package__/bundle/main.py', 'B']);
  assert.equal(isolated.runtime.Sk.__movieOriginalCompile, compiler);
  const absent = `import io
class Spider:
 def homeContent(self, filter):
  result=[]
  for filename in ['data.txt','/__package__/bundle/data.txt']:
   try: open(filename).read(); result.append('unexpected')
   except FileNotFoundError: result.append('missing')
  return result
`;
  assert.deepEqual(await run(absent, undefined, {}, isolated), ['missing', 'missing']);
  assert.deepEqual(isolated.counts(), [0, 0]);
  const override = {'io.py':"raise RuntimeError('overrode io')", '_movie_package.py':"raise RuntimeError('overrode package')"};
  assert.deepEqual(await run(simple, packageFor(simple), override), ['/__package__/bundle/main.py', 'first']);
  console.log('PASS Python package sequential source isolation, compiler reset and protected reader');

  const invalid = [];
  function rejected(data, name) {
    assert.throws(() => isolated.runtime.createPythonSpider(simple, {}, isolated.sibling, data), undefined, name);
    invalid.push(name);
  }
  for (const data of [{}, 1, false, 'package', [], {entry:'main.py', files:[]}]) {
    rejected(data, 'invalid package shape ' + JSON.stringify(data));
  }
  for (const name of ['../main.py', '/main.py', 'a//main.py', 'a/./main.py', 'a\\main.py', 'a:main.py', "a'main.py", 'a\"main.py']) {
    rejected({entry:name, files:{[name]:''}}, 'unsafe path ' + name);
  }
  for (const bytes of ['Zg=', 'Zg===', 'Z===', 'Zh==', 'Zm9=', 'Zm$v', 'Zg==\n', '====']) {
    rejected({entry:'main.py', files:{'main.py':bytes}}, 'invalid base64 ' + JSON.stringify(bytes));
  }
  rejected({entry:'main.py', files:{}}, 'missing entry');
  rejected({entry:'main.py', files:{'main.py':'', 'main.py/child':''}}, 'file directory conflict');
  rejected({entry:'main.py', files:Object.fromEntries(Array.from({length:257}, (_, i) => [i ? 'f' + i : 'main.py', '']))}, 'file count');
  const max = Buffer.alloc(2 * 1024 * 1024).toString('base64');
  rejected({entry:'main.py', files:{'main.py':Buffer.alloc(2 * 1024 * 1024 + 1).toString('base64')}}, 'single decoded byte size');
  rejected({entry:'main.py', files:{'main.py':max, a:max, b:max, c:'AA=='}}, 'total decoded byte size');
  console.log('PASS Python package ' + invalid.length + ' schema, canonical base64 and decoded resource limits');
}
module.exports = {run};
if (require.main === module) main().catch(error => { console.error(error.stack || String(error)); process.exitCode = 1; });
