// Execute the exact bytes/modules emitted by the real Android package importer.
const fs = require('node:fs');
const assert = require('node:assert/strict');
const {run} = require('../../scripts/test_python_package.js');
async function main() {
  const input = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  const expected = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
  const actual = await run(input.source, input.packageData, input.modules);
  assert.deepEqual(actual, expected);
  console.log('Android ZIP -> raw package snapshot -> shared Python: ' + Object.keys(expected).length + ' CPython oracle cases passed');
}
main().catch(error => { console.error(error.stack || String(error)); process.exitCode = 1; });
