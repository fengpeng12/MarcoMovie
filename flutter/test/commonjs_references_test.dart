import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/js_source_host.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  tearDown(JsSourceHost.closeAll);

  test(
    'CommonJS dependencies ignore comments, strings, regexes and members',
    () {
      const source = r'''
// require('./missing-comment.js')
/* require('./missing-block.js') */
const text = "require('./missing-string.js')";
const escaped = 'It\'s require("./missing-escaped.js")';
const pattern = /require('missing-regex')/;
if (true) /require('missing-control-regex')/.test(text);
{ /require('missing-block-regex')/.test(text); }
class Declaration {} /require('missing-class-regex')/.test(text);
try {} catch {} /require('missing-catch-regex')/.test(text);
const classRatio = class Expression {} / require('./class-denominator.js') / 2;
const member = object.require('./missing-member.js');
object?.require('./missing-optional-member.js');
const other = $require('./missing-identifier.js');
const real = require /* between */ ( /* argument */ './helper.js.cjs' /* end */ );
const data = require('./co\u0064ed.json');
const ratio = 12 / require('./denominator.js') / 2;
const objectRatio = {} / require('./object-denominator.js') / 2;
const fnRatio = function() {} / require('./function-denominator.js') / 2;
const arrowRatio = (() => {}) / require('./arrow-denominator.js') / 2;
const memberRatio = object.if(true) / require('./member-denominator.js') / 2;
require('./dynamic-' + name);
''';
      expect(JsSourceHost.commonJsReferences(source), [
        './class-denominator.js',
        './helper.js.cjs',
        './coded.json',
        './denominator.js',
        './object-denominator.js',
        './function-denominator.js',
        './arrow-denominator.js',
        './member-denominator.js',
      ]);
    },
  );

  test('CommonJS scans template expressions but not raw template text', () {
    const source = r'''
const text = `require('./missing-template.js') ${
  require('./in-expression.js').name
} ${`require('./missing-nested-text.js') ${
  ({value: require('./nested-expression.js')}).value
}`} ${/require('missing-expression-regex')/.source}`;
const escaped = `\${require('./missing-escaped-expression.js')}`;
''';
    expect(JsSourceHost.commonJsReferences(source), [
      './in-expression.js',
      './nested-expression.js',
    ]);
  });

  test('CommonJS source import fetches only real relative modules', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final base = 'http://127.0.0.1:${server.port}';
    final requested = <String>[];
    final modules = {
      '/main.js.cjs': r'''
// require('./missing-comment.js')
/* require('./missing-block.js') */
const description = "require('./missing-string.js')";
const pattern = /require('missing-regex')/;
if (true) /require('missing-control-regex')/.test(description);
const title = `require('./missing-template.js'): ${require('./helper.js.cjs').title}`;
module.exports = {home(){return {list:[{vod_id:'one',vod_name:title}]}}};
''',
      '/helper.js.cjs': "exports.title = 'real helper';",
    };
    server.listen((request) async {
      requested.add(request.uri.path);
      final body = modules[request.uri.path];
      request.response.statusCode = body == null ? 404 : 200;
      request.response.write(body ?? 'missing');
      await request.response.close();
    });
    final client = CmsClient();
    final imported = await client.resolveConfigInput(
      urlInput: '$base/main.js.cjs',
    );
    final home = await client.fetchHome(imported.config.sites.single);
    expect(
      home.$2.videos.single.title,
      "require('./missing-template.js'): real helper",
    );
    expect(requested.toSet(), modules.keys.toSet());
  });
}
