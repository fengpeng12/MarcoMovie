// Run the shipped Python module against an independently generated CPython oracle.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.join(__dirname, '..');
async function run(source) {
  const context = vm.createContext({console, setTimeout, clearTimeout});
  for (const file of ['skulpt.min.js', 'skulpt-stdlib.js', 'compiled-modules.js', 'json.js', 'io.js', 'spider.js']) {
    vm.runInContext(fs.readFileSync(path.join(root, 'android/src/main/assets/python-host', file), 'utf8'), context, {filename:file});
  }
  const spider = context.createPythonSpider(source);
  await spider.init('');
  return JSON.parse(JSON.stringify(await spider.home(true)));
}
async function main() {
  const expected = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/python_json_expected.json'), 'utf8'));
  const actual = await run(fs.readFileSync(path.join(__dirname, 'fixtures/python_json_contract.py'), 'utf8'));
  const failures = [];
  for (const key of Object.keys(expected)) {
    try { assert.deepEqual(actual[key], JSON.parse(JSON.stringify(expected[key])), key); }
    catch (error) { failures.push({key, actual:actual[key], expected:expected[key]}); }
  }
  if (failures.length) throw Error(JSON.stringify(failures, null, 2));
  console.log('PASS Python JSON: ' + Object.keys(expected).length + ' CPython oracle cases');
  const limits = await run(`import json
class Spider:
 def homeContent(self, filter):
  result = []
  for case in range(5):
   try:
    if case == 0: json.loads('[' * 82 + '0' + ']' * 82)
    if case == 1: json.loads('"' + 'x' * (2 * 1024 * 1024) + '"')
    if case == 2: json.dumps({'a':1}, indent=' ' * 1025)
    if case == 3: json.dumps(object(), default=lambda v: v, check_circular=False)
    if case == 4: json.loads(b'\\xff\\xfe{\\x00')
   except (ValueError, NotImplementedError): result.append(case)
  return result
`);
  assert.deepEqual(limits, [0, 1, 2, 3, 4]);
  console.log('PASS Python JSON nesting, size, indentation, default recursion and encoding limits');
}
module.exports = {run};
if (require.main === module) main().catch(error => { console.error(String(error)); process.exitCode = 1; });
