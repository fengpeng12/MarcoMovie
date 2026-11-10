const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {run} = require('./test_python_json.js');
async function main() {
  const expected = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/python_io_expected.json'), 'utf8'));
  const actual = await run(fs.readFileSync(path.join(__dirname, 'fixtures/python_io_contract.py'), 'utf8'));
  const failures = [];
  for (const key of Object.keys(expected)) {
    try { assert.deepEqual(actual[key], expected[key], key); }
    catch (error) { failures.push({key, actual:actual[key], expected:expected[key]}); }
  }
  if (failures.length) throw Error(JSON.stringify(failures, null, 2));
  console.log('PASS Python IO: ' + Object.keys(expected).length + ' CPython oracle cases');
  const limits = await run(`import io
class Spider:
 def homeContent(self, filter):
  result = []
  for action in [lambda: io.StringIO('x' * (2 * 1024 * 1024 + 1)),
                 lambda: io.BytesIO(b'x' * (2 * 1024 * 1024 + 1)),
                 lambda: io.StringIO(newline=None),
                 lambda: io.BytesIO().getbuffer(),
                 lambda: io.BytesIO().readinto(b'x')]:
   try: action()
   except (ValueError, NotImplementedError): result.append(True)
  stream = io.BytesIO(b'A'); stream.seek(2 * 1024 * 1024)
  try: stream.write(b'B')
  except ValueError: result.append(stream.getvalue() == b'A' and stream.tell() == 2 * 1024 * 1024)
  return result
`);
  assert.deepEqual(limits, [true, true, true, true, true, true]);
  console.log('PASS Python IO bounded allocation and explicit unsupported operations');
}
main().catch(error => { console.error(String(error)); process.exitCode = 1; });
