/// A lexical scan of static module declarations, not a rewrite of user code.
/// Literals/comments are consumed before looking for import/export keywords.
class JsSourceSyntax {
  JsSourceSyntax(String source) {
    final tokens = _JsModuleLexer(source).scan();
    for (var i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      // A Python `import requests` also starts like an incomplete JS import.
      // Recognize actual Spider declarations after consuming comments/literals,
      // so examples embedded in a JS template cannot select the Python host.
      if (token.identifier &&
          (i == 0 || token.newLine) &&
          i + 2 < tokens.length) {
        final name = tokens[i + 1], next = tokens[i + 2];
        if (token.text == 'class' &&
            name.identifier &&
            name.text == 'Spider' &&
            (next.text == ':' || next.text == '(')) {
          hasPythonSpider = true;
        }
        if (token.text == 'def' &&
            name.identifier &&
            const {'homeContent', 'searchContent'}.contains(name.text) &&
            next.text == '(') {
          hasPythonSpider = true;
        }
      }
      if (!token.literal && token.identifier) {
        final previous = i == 0 ? null : tokens[i - 1];
        if (previous?.text != '.') {
          var member = token.text == 'module'
              ? _propertyEnd(tokens, i + 1, 'exports')
              : token.text == 'exports'
              ? _propertyEnd(tokens, i + 1)
              : -1;
          if (member >= 0) {
            while (member < tokens.length) {
              final next = _propertyEnd(tokens, member);
              if (next < 0) break;
              member = next;
            }
            if (member < tokens.length &&
                tokens[member].text == '=' &&
                (member + 1 >= tokens.length ||
                    tokens[member + 1].text != '=')) {
              hasCommonJsExports = true;
            }
          }
        }
        if (token.topLevel &&
            i + 2 < tokens.length &&
            const ['var', 'let', 'const'].contains(token.text) &&
            tokens[i + 1].identifier &&
            tokens[i + 2].text == '=') {
          if (tokens[i + 1].text == 'rule') hasRuleDeclaration = true;
          if (tokens[i + 1].text == '__jsEvalReturn') hasCatSpider = true;
        }
        if (token.topLevel &&
            token.text == 'function' &&
            i + 2 < tokens.length &&
            tokens[i + 1].identifier &&
            tokens[i + 1].text == '__jsEvalReturn' &&
            tokens[i + 2].text == '(') {
          hasCatSpider = true;
        }
      }
      if (!token.topLevel || token.literal || i + 1 >= tokens.length) continue;
      final previous = i == 0 ? null : tokens[i - 1];
      if (previous?.text == '.' || previous?.text == '?.') continue;
      if (i > 0 &&
          !token.newLine &&
          previous!.text != ';' &&
          previous.text != '}')
        continue;
      final next = tokens[i + 1];
      if (token.text == 'import') {
        if (next.text == '(' || next.text == '.') continue;
        if (next.literal) {
          isModule = true;
          references.add(next.text);
          continue;
        }
        if (next.text != '{' && next.text != '*' && !next.identifier) continue;
        isModule = true;
      } else if (token.text == 'export') {
        if (!const {
          'default',
          'const',
          'let',
          'var',
          'function',
          'class',
          'async',
          '{',
          '*',
        }.contains(next.text))
          continue;
        isModule = true;
        if (next.text != '{' && next.text != '*') continue;
      } else {
        continue;
      }
      // Import/export clauses can span lines and contain a named binding list.
      for (var j = i + 1; j < tokens.length; j++) {
        final part = tokens[j];
        if (part.topLevel && part.text == ';') break;
        if (j > i + 1 &&
            part.topLevel &&
            const {'import', 'export'}.contains(part.text))
          break;
        if (part.topLevel &&
            !part.literal &&
            part.text == 'from' &&
            j + 1 < tokens.length &&
            tokens[j + 1].literal) {
          references.add(tokens[j + 1].text);
          break;
        }
      }
    }
  }

  bool isModule = false;
  bool hasCommonJsExports = false;
  bool hasRuleDeclaration = false;
  bool hasCatSpider = false;
  bool hasPythonSpider = false;
  bool get hasSpiderExports => isModule || hasCommonJsExports || hasCatSpider;
  bool get hasDrpyRule => hasRuleDeclaration && !hasSpiderExports;
  final references = <String>[];

  static int _propertyEnd(
    List<_JsModuleToken> tokens,
    int index, [
    String? name,
  ]) {
    if (index + 1 >= tokens.length) return -1;
    if (tokens[index].text == '.' &&
        tokens[index + 1].identifier &&
        (name == null || tokens[index + 1].text == name))
      return index + 2;
    if (tokens[index].text != '[') return -1;
    if (name != null) {
      return index + 2 < tokens.length &&
              tokens[index + 1].literal &&
              tokens[index + 1].text == name &&
              tokens[index + 2].text == ']'
          ? index + 3
          : -1;
    }
    var depth = 1;
    for (var i = index + 1; i < tokens.length; i++) {
      if (tokens[i].literal) continue;
      if (tokens[i].text == '[') depth++;
      if (tokens[i].text == ']' && --depth == 0) return i + 1;
    }
    return -1;
  }
}

class _JsModuleToken {
  const _JsModuleToken(
    this.text,
    this.topLevel,
    this.newLine, {
    this.literal = false,
    this.identifier = false,
  });
  final String text;
  final bool topLevel, newLine, literal, identifier;
}

class _JsModuleLexer {
  _JsModuleLexer(this.source);
  final String source;
  int at = 0;
  bool newLine = false;
  String char([int offset = 0]) =>
      at + offset < source.length ? source[at + offset] : '';
  static final _word = RegExp(r'[\w$\u0080-\uffff]');
  bool word(String c) => c.isNotEmpty && _word.hasMatch(c);
  bool regexAfter(String token) => const {
    '',
    '(',
    '[',
    '{',
    ',',
    ';',
    ':',
    '=',
    '!',
    '?',
    '&',
    '|',
    '+',
    '-',
    '*',
    '%',
    '^',
    '~',
    '<',
    '>',
    'return',
    'throw',
    'case',
    'delete',
    'void',
    'typeof',
    'yield',
    'await',
    'else',
    'do',
    'in',
    'of',
  }.contains(token);

  List<_JsModuleToken> scan() {
    final tokens = <_JsModuleToken>[];
    var braces = 0, brackets = 0, parentheses = 0;
    var previous = '';
    while (at < source.length) {
      if (skipTrivia()) continue;
      final top = braces == 0 && brackets == 0 && parentheses == 0;
      final line = newLine;
      newLine = false;
      final c = char();
      late _JsModuleToken token;
      if (c == '"' || c == "'") {
        token = _JsModuleToken(quoted(), top, line, literal: true);
        previous = '<string>';
      } else if (c == '`') {
        template();
        token = _JsModuleToken('<template>', top, line);
        previous = token.text;
      } else if (c == '/' && regexAfter(previous) && regex()) {
        token = _JsModuleToken('<regex>', top, line);
        previous = token.text;
      } else if (word(c)) {
        final start = at++;
        while (word(char())) {
          at++;
        }
        final text = source.substring(start, at);
        token = _JsModuleToken(
          text,
          top,
          line,
          identifier: !RegExp(r'^\d').hasMatch(text),
        );
        previous = text;
      } else {
        at++;
        if (c == '{') braces++;
        if (c == '}') braces--;
        if (c == '[') brackets++;
        if (c == ']') brackets--;
        if (c == '(') parentheses++;
        if (c == ')') parentheses--;
        token = _JsModuleToken(c, top, line);
        previous = c;
      }
      tokens.add(token);
    }
    return tokens;
  }

  bool skipTrivia() {
    final c = char();
    if (c.isNotEmpty && c.trim().isEmpty) {
      if (c == '\n' || c == '\r' || c == '\u2028' || c == '\u2029')
        newLine = true;
      at++;
      return true;
    }
    if ((c == '/' && char(1) == '/') ||
        (at == 0 && c == '#' && char(1) == '!')) {
      while (at < source.length && char() != '\n' && char() != '\r') {
        at++;
      }
      return true;
    }
    if (c == '/' && char(1) == '*') {
      at += 2;
      while (at < source.length && !(char() == '*' && char(1) == '/')) {
        if (char() == '\n' || char() == '\r') newLine = true;
        at++;
      }
      at = (at + 2).clamp(0, source.length);
      return true;
    }
    return false;
  }

  String quoted() {
    final quote = char();
    at++;
    final value = StringBuffer();
    while (at < source.length) {
      final c = char();
      at++;
      if (c == quote) break;
      if (c != r'\') {
        value.write(c);
        continue;
      }
      if (at >= source.length) break;
      final escaped = char();
      at++;
      if (escaped == '\n' || escaped == '\r') {
        if (escaped == '\r' && char() == '\n') at++;
        continue;
      }
      if (escaped == 'x' || escaped == 'u') {
        final brace = escaped == 'u' && char() == '{';
        if (brace) at++;
        final end = brace
            ? source.indexOf('}', at)
            : at + (escaped == 'x' ? 2 : 4);
        if (end >= at && end <= source.length) {
          final cp = int.tryParse(source.substring(at, end), radix: 16);
          if (cp != null && cp <= 0x10ffff) {
            value.writeCharCode(cp);
            at = end + (brace ? 1 : 0);
            continue;
          }
        }
      }
      value.write(
        const {
              'n': '\n',
              'r': '\r',
              't': '\t',
              'b': '\b',
              'f': '\f',
              'v': '\u000b',
              '0': '\u0000',
            }[escaped] ??
            escaped,
      );
    }
    return value.toString();
  }

  bool regex() {
    var cursor = at + 1;
    var inClass = false;
    while (cursor < source.length) {
      final c = source[cursor++];
      if (c == '\n' || c == '\r') return false;
      if (c == r'\') {
        cursor++;
        continue;
      }
      if (c == '[') inClass = true;
      if (c == ']') inClass = false;
      if (c == '/' && !inClass) {
        at = cursor;
        while (word(char())) {
          at++;
        }
        return true;
      }
    }
    return false;
  }

  void template() {
    at++;
    while (at < source.length) {
      final c = char();
      at++;
      if (c == r'\') {
        if (at < source.length) at++;
        continue;
      }
      if (c == '`') return;
      if (c != r'$' || char() != '{') continue;
      at++;
      var depth = 1;
      var previous = '';
      while (at < source.length && depth > 0) {
        if (skipTrivia()) continue;
        final inner = char();
        if (inner == '"' || inner == "'") {
          quoted();
          previous = '<string>';
        } else if (inner == '`') {
          template();
          previous = '<template>';
        } else if (inner == '/' && regexAfter(previous) && regex()) {
          previous = '<regex>';
        } else {
          at++;
          if (inner == '{') depth++;
          if (inner == '}') depth--;
          previous = inner;
        }
      }
    }
  }
}
