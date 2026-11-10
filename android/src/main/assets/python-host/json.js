// Bounded JSON compatibility for imported Python sources. Preserve Python number,
// key order and hook semantics instead of silently dropping dumps/loads options.
function installPythonJson(library) {
  function nativeModule() {
    const py = Sk.ffi.remapToPy;
    function scan(input, strict) {
      const text = Sk.ffi.remapToJs(input), rejectControls = Sk.ffi.remapToJs(strict);
      let at = 0, nodes = 0;
      const fail = (message, position = at) => { throw {message, position}; };
      const white = () => { while (at < text.length && /[ \t\r\n]/.test(text[at])) at++; };
      function string() {
        const start = at++;
        let value = '';
        while (at < text.length) {
          const c = text[at++];
          if (c === '"') return value;
          if (c === '\\') {
            if (at >= text.length) fail('Unterminated string starting at', start);
            const escaped = text[at++], map = {'"':'"', '\\':'\\', '/':'/', b:'\b', f:'\f', n:'\n', r:'\r', t:'\t'};
            if (Object.prototype.hasOwnProperty.call(map, escaped)) value += map[escaped];
            else if (escaped === 'u') {
              const digits = text.slice(at, at + 4);
              if (!/^[a-fA-F0-9]{4}$/.test(digits)) fail('Invalid \\uXXXX escape', at - 1);
              value += String.fromCharCode(parseInt(digits, 16)); at += 4;
            } else fail('Invalid \\escape', at - 2);
          } else {
            if (rejectControls && c.charCodeAt(0) < 32) fail('Invalid control character at', at - 1);
            value += c;
          }
        }
        fail('Unterminated string starting at', start);
      }
      function value(depth) {
        if (depth > 80 || ++nodes > 100000) throw new Sk.builtin.ValueError('JSON exceeds local nesting or item limits');
        white(); const c = text[at];
        if (c === '"') return ['value', string()];
        if (c === '{') {
          at++; white(); const pairs = [];
          if (text[at] === '}') { at++; return ['object', pairs]; }
          while (true) {
            if (text[at] !== '"') fail('Expecting property name enclosed in double quotes');
            const key = string(); white();
            if (text[at++] !== ':') fail("Expecting ':' delimiter", at - 1);
            pairs.push([key, value(depth + 1)]); white();
            if (text[at] === '}') { at++; return ['object', pairs]; }
            if (text[at++] !== ',') fail("Expecting ',' delimiter", at - 1);
            white();
          }
        }
        if (c === '[') {
          at++; white(); const items = [];
          if (text[at] === ']') { at++; return ['array', items]; }
          while (true) {
            items.push(value(depth + 1)); white();
            if (text[at] === ']') { at++; return ['array', items]; }
            if (text[at++] !== ',') fail("Expecting ',' delimiter", at - 1);
            const comma = at - 1;
            white();
            if (text[at] === ']') fail('Illegal trailing comma before end of array', comma);
          }
        }
        for (const [literal, result] of [['true',true],['false',false],['null',null]]) {
          if (text.slice(at, at + literal.length) === literal) { at += literal.length; return ['value',result]; }
        }
        for (const literal of ['NaN','Infinity','-Infinity']) {
          if (text.slice(at, at + literal.length) === literal) { at += literal.length; return ['constant',literal]; }
        }
        const number = /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/.exec(text.slice(at));
        if (number) { at += number[0].length; return [/[.eE]/.test(number[0]) ? 'float' : 'int', number[0]]; }
        fail('Expecting value');
      }
      try {
        const result = value(0); white();
        if (at !== text.length) fail('Extra data');
        return py([true, result]);
      } catch (error) {
        if (typeof error.position !== 'number') throw error;
        return py([false, error.message, Array.from(text.slice(0, error.position)).length]);
      }
    }
    return {scan: new Sk.builtin.func(scan), float_text: new Sk.builtin.func(function(value) {
      const number = Sk.ffi.remapToJs(value), magnitude = Math.abs(number);
      if (Object.is(number, -0)) return new Sk.builtin.str('-0.0');
      let text = magnitude && (magnitude >= 1e16 || magnitude < 1e-4) ? number.toExponential() : number.toString();
      text = text.replace(/e([+-])(\d)$/, 'e$10$2');
      if (!/[.e]/.test(text)) text += '.0';
      return new Sk.builtin.str(text);
    })};
  }
  library['src/lib/_movie_json.js'] = 'var $builtinmodule = ' + nativeModule.toString() + ';';
  library['src/lib/json/__init__.py'] = String.raw`
import _movie_json

_LIMIT = 2 * 1024 * 1024

class JSONDecodeError(ValueError):
    def __init__(self, msg, doc, pos):
        self.msg, self.doc, self.pos = msg, doc, pos
        self.lineno = doc.count('\n', 0, pos) + 1
        self.colno = pos - doc.rfind('\n', 0, pos)
        ValueError.__init__(self, '%s: line %d column %d (char %d)' % (msg, self.lineno, self.colno, pos))

def loads(s, cls=None, object_hook=None, parse_float=None, parse_int=None, parse_constant=None, object_pairs_hook=None, strict=True, **kw):
    if cls is not None: raise NotImplementedError('custom JSON decoder classes are unavailable')
    if kw: raise TypeError('unknown JSON decoder options: ' + ', '.join(kw))
    if isinstance(s, bytes):
        if len(s) > _LIMIT: raise ValueError('JSON exceeds local size limit')
        if s.startswith(b'\xff\xfe') or s.startswith(b'\xfe\xff') or b'\x00' in s[:4]:
            raise NotImplementedError('binary JSON currently requires UTF-8')
        if s.startswith(b'\xef\xbb\xbf'): s = s[3:]
        s = s.decode('utf-8')
    if not isinstance(s, str): raise TypeError('JSON input must be str or bytes')
    if len(s) > _LIMIT: raise ValueError('JSON exceeds local size limit')
    if s.startswith('\ufeff'): raise JSONDecodeError('Unexpected UTF-8 BOM (decode using utf-8-sig)', s, 0)
    result = _movie_json.scan(s, bool(strict))
    if not result[0]: raise JSONDecodeError(result[1], s, result[2])
    def convert(node):
        kind, value = node
        if kind == 'value': return value
        if kind == 'int': return (int if parse_int is None else parse_int)(value)
        if kind == 'float': return (float if parse_float is None else parse_float)(value)
        if kind == 'constant': return parse_constant(value) if parse_constant is not None else float(value)
        if kind == 'array': return [convert(v) for v in value]
        pairs = [(k, convert(v)) for k, v in value]
        if object_pairs_hook is not None: return object_pairs_hook(pairs)
        obj = dict(pairs)
        return object_hook(obj) if object_hook is not None else obj
    return convert(result[1])

def dumps(obj, skipkeys=False, ensure_ascii=True, check_circular=True, allow_nan=True, cls=None, indent=None, separators=None, default=None, sort_keys=False, **kw):
    if cls is not None: raise NotImplementedError('custom JSON encoder classes are unavailable')
    if kw: raise TypeError('unknown JSON encoder options: ' + ', '.join(kw))
    if isinstance(indent, int):
        if indent > 1024: raise ValueError('JSON indentation exceeds local limit')
        indent = ' ' * max(indent, 0)
    if indent is not None and not isinstance(indent, str): raise TypeError('indent must be an integer, string or None')
    if indent is not None and len(indent) > 1024: raise ValueError('JSON indentation exceeds local limit')
    item_sep, key_sep = (', ', ': ') if indent is None else (',', ': ')
    if separators is not None:
        item_sep, key_sep = separators
        if not isinstance(item_sep, str) or not isinstance(key_sep, str): raise TypeError('separators must be strings')
    parts, active = [], set()
    size, visits = [0], [0]
    def emit(text):
        size[0] += len(text)
        if size[0] > _LIMIT: raise ValueError('JSON exceeds local size limit')
        parts.append(text)
    def quoted(text):
        if len(text) > _LIMIT: raise ValueError('JSON exceeds local size limit')
        emit('"')
        escaped = {'"':'\\"', '\\':'\\\\', '\b':'\\b', '\f':'\\f', '\n':'\\n', '\r':'\\r', '\t':'\\t'}
        run = []
        for char in text:
            cp = ord(char)
            if char in escaped: run.append(escaped[char])
            elif cp < 32 or ensure_ascii and cp >= 127:
                if cp > 65535:
                    cp -= 65536
                    run.append('\\u%04x\\u%04x' % (55296 + (cp >> 10), 56320 + (cp & 1023)))
                else: run.append('\\u%04x' % cp)
            else: run.append(char)
            if len(run) >= 256: emit(''.join(run)); run = []
        emit(''.join(run)); emit('"')
    def number(value):
        if isinstance(value, int): return str(value)
        if value != value: result = 'NaN'
        elif value == float('inf'): result = 'Infinity'
        elif value == -float('inf'): result = '-Infinity'
        else: return _movie_json.float_text(value)
        if not allow_nan: raise ValueError('Out of range float values are not JSON compliant')
        return result
    def encode(value, depth):
        visits[0] += 1
        if depth > 80 or visits[0] > 100000: raise ValueError('JSON exceeds local nesting or item limits')
        if value is None: emit('null'); return
        if value is True: emit('true'); return
        if value is False: emit('false'); return
        if isinstance(value, str): quoted(value); return
        if isinstance(value, (int, float)): emit(number(value)); return
        ident = id(value)
        if check_circular and ident in active: raise ValueError('Circular reference detected')
        active.add(ident)
        try:
            if isinstance(value, (list, tuple)):
                emit('[')
                for i, element in enumerate(value):
                    if i: emit(item_sep)
                    if indent is not None: emit('\n' + indent * (depth + 1))
                    encode(element, depth + 1)
                if value and indent is not None: emit('\n' + indent * depth)
                emit(']')
            elif isinstance(value, dict):
                emit('{'); count = 0
                items = sorted(value.items()) if sort_keys else value.items()
                for key, element in items:
                    if not isinstance(key, str):
                        if key is True: key = 'true'
                        elif key is False: key = 'false'
                        elif key is None: key = 'null'
                        elif isinstance(key, (int, float)): key = number(key)
                        elif skipkeys: continue
                        else: raise TypeError('JSON object keys must be str, int, float, bool or None')
                    if count: emit(item_sep)
                    if indent is not None: emit('\n' + indent * (depth + 1))
                    quoted(key); emit(key_sep); encode(element, depth + 1); count += 1
                if count and indent is not None: emit('\n' + indent * depth)
                emit('}')
            elif default is not None: encode(default(value), depth + 1)
            else: raise TypeError('Object is not JSON serializable')
        finally: active.discard(ident)
    encode(obj, 0)
    return ''.join(parts)

def load(fp, **kw): return loads(fp.read(), **kw)
def dump(obj, fp, **kw):
    fp.write(dumps(obj, **kw))
`;
}
