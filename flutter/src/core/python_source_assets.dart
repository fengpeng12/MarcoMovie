import 'package:flutter/services.dart' show rootBundle;

// Asset text can be reused; each source still gets its own parser and Python VM.
// Do not instantiate the HTML dependency bundle for scripts which never use it.
Future<List<String>>? _prelude;

Future<List<String>> loadPythonSourcePrelude() => _prelude ??= _loadPrelude();

Future<List<String>> _loadPrelude() async {
  try {
    final assets = await Future.wait([
      rootBundle.loadString('assets/python-host/parser.js'),
      for (final name in [
        'skulpt.min.js',
        'skulpt-stdlib.js',
        'compiled-modules.js',
        'html.js',
        'regex.js',
        'json.js',
        'io.js',
        'spider.js',
      ])
        rootBundle.loadString('assets/python-host/$name'),
    ]);
    return [
      '''globalThis.__moviePythonHtmlParser = function() {
const navigator = {appName:'Netscape'};
${assets.first}
globalThis.__moviePythonHtmlParser = () => MoviePythonHtml;
return MoviePythonHtml;
};''',
      ...assets.skip(1),
    ];
  } catch (_) {
    _prelude = null;
    rethrow;
  }
}
