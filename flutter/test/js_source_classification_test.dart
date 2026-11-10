import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_parser.dart';
import 'package:marco_movie/core/js_source_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('DRPY rule selection ignores executable-looking comments and literals', () {
    for (final prefix in [
      '// export default rule;\n',
      '/* module.exports={}; exports.home=function(){}; */\n',
      'const text = "export default {}; module.exports={};";\n',
      "const pattern=/export default|module.exports=|__jsEvalReturn/;\n",
      'const text=`export default {}; \${`module.exports={}`} function __jsEvalReturn(){}`;\n',
    ]) {
      final source =
          '${prefix}var /* annotation */ rule={title:"fixture",host:"https://fixture.invalid"};';
      expect(JsSourceHost.hasSpiderExports(source), isFalse, reason: prefix);
      expect(JsSourceHost.hasDrpyRule(source), isTrue, reason: prefix);
      expect(CmsParser.looksLikeDrpyRule(source), isTrue);
      expect(
        CmsParser.parseConfig(source).sites.single.api,
        'csp_LocalRule.js',
      );
    }
  });

  test(
    'real module or Cat exports take precedence over rule-shaped variables',
    () {
      for (final export in [
        'export default {home(){return {}}};',
        'module.exports = {home(){return {}}};',
        'module["exports"] = {home(){return {}}};',
        'exports["home"] = function(){return {}};',
        'exports.home = function(){return {}};',
        'function __jsEvalReturn(){return {home(){return {}}}}',
      ]) {
        final source = 'var rule={}; $export';
        expect(JsSourceHost.hasSpiderExports(source), isTrue, reason: export);
        expect(JsSourceHost.hasDrpyRule(source), isFalse, reason: export);
        expect(
          CmsParser.parseConfig(source).sites.single.api,
          'csp_LocalScript.js',
        );
      }
    },
  );

  test(
    'literal and nested rule declarations do not create DRPY entry points',
    () {
      for (final source in [
        'const text="var rule={};";',
        '/* var rule={}; */ const text="not a source";',
        'const text=`var rule={};`;',
        'function helper(){var rule={};return rule;}',
      ]) {
        expect(CmsParser.looksLikeScript(source), isFalse);
        expect(CmsParser.looksLikeDrpyRule(source), isFalse);
      }
      expect(CmsParser.isExecutableJs('const exports={};'), isFalse);
      expect(CmsParser.isExecutableJs('if(module.exports===value){}'), isFalse);
    },
  );

  test('CommonJS entry executes despite Cat text in a comment', () async {
    final result = await JsSourceHost.invoke(
      entry: 'pkg://local/source.js',
      modules: {
        'pkg://local/source.js':
            '// function __jsEvalReturn() {}\nmodule["exports"]={home:function(){return {list:[]}}};',
      },
      method: 'home',
      arguments: [],
    );
    expect(result, '{"list":[]}');
  });
}
