"""Self-authored protocol cases; CPython generates the independent oracle."""
import json


class Stream:
    def __init__(self, value=''):
        self.value = value
        self.reads = 0
    def read(self):
        self.reads += 1
        return self.value
    def write(self, value):
        if not isinstance(value, str): raise TypeError('text required')
        self.value += value
        return len(value)


def contract():
    result = {}
    value = {'z': '中文🎬\n\t\\"', 'a': [True, None, False, 1, -2, 1.5, -0.0]}
    result['defaults'] = json.dumps(value)
    result['signed_payload'] = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
    result['pretty'] = json.dumps(value, sort_keys=True, indent=2)
    result['tabs'] = json.dumps({'a': [1, {}, []]}, indent='\t')
    result['indent_zero'] = json.dumps([1, {'x': 2}], indent=0)
    result['slash_control'] = json.dumps('/\x00\x1f\b\f\r\u007f\u0080')
    result['non_string_keys'] = json.dumps({True: 1, None: 2, 3: '三', 1.5: False})
    result['skip_keys'] = json.dumps({(1, 2): 1, 'kept': 2}, skipkeys=True)
    result['custom_default'] = json.dumps({'x': {3, 1}}, default=lambda value: sorted(value))
    result['nan_output'] = json.dumps([float('nan'), float('inf'), -float('inf')])
    result['float_output'] = json.dumps([1.0, 1e20, 1e21, 1e-5, 1e-6, 1.2345678901234567])
    result['big_int'] = str(json.loads('9007199254740993123456789'))
    result['big_int_output'] = json.dumps({'id': 9007199254740993123456789})
    result['key_order'] = list(json.loads('{"9":0,"1":0,"a":0,"__proto__":0}').keys())
    result['duplicate_keys'] = json.loads('{"a":1,"a":2,"b":3}')
    result['pairs_hook'] = json.loads('{"a":1,"a":2,"nested":{"b":3}}', object_pairs_hook=lambda pairs: pairs)
    result['hook_priority'] = json.loads('{"a":1}', object_pairs_hook=lambda pairs: pairs, object_hook=lambda obj: 'wrong')
    result['object_hook'] = json.loads('{"nested":{"a":1}}', object_hook=lambda obj: list(obj.items()))
    result['number_hooks'] = json.loads('[123,1.25,1e3,NaN,Infinity,-Infinity]', parse_int=lambda s: 'i:' + s, parse_float=lambda s: 'f:' + s, parse_constant=lambda s: 'c:' + s)
    result['unicode'] = json.loads('"\u4e2d\\ud83c\\udfac"')
    result['control_allowed'] = json.loads('"a\nb"', strict=False)
    result['bytes'] = json.loads(b'\xef\xbb\xbf{"value":"\xe4\xb8\xad"}')
    stream = Stream()
    result['dump_return'] = json.dump(value, stream, ensure_ascii=False, separators=(',', ':'))
    result['stream_text'] = stream.value
    result['load'] = json.load(stream)
    result['read_count'] = stream.reads
    errors = []
    for doc in ['', ' [1,]', '{"a" 1}', '{"a":1', '{x:1}', '"bad\\q"', '"\\uxxxx"', '"abc', 'true false', '"a\nb"', '{"🎬":\n ?}', '\ufeff{}', '01', '1e+', '-']:
        try: json.loads(doc)
        except json.JSONDecodeError as e:
            errors.append([e.doc, e.pos, e.lineno, e.colno, isinstance(e, ValueError)])
    result['errors'] = errors
    invalid = []
    cyclic = []; cyclic.append(cyclic)
    class FailingStream:
        def read(self): raise RuntimeError('read failure')
        def write(self, value): raise RuntimeError('write failure')
    cases = [lambda: json.dumps(cyclic), lambda: json.dumps(float('nan'), allow_nan=False),
             lambda: json.dumps({(1,): 1}), lambda: json.dumps(b'x'), lambda: json.loads(42),
             lambda: json.dumps({'x': 1}, wrong=True), lambda: json.loads('{}', wrong=True),
             lambda: json.loads('1', parse_int=lambda s: 1 // 0),
             lambda: json.load(FailingStream()), lambda: json.dump({}, FailingStream())]
    for case in cases:
        try: case()
        except (ValueError, TypeError, ZeroDivisionError, RuntimeError) as e: invalid.append(type(e).__name__)
    result['invalid'] = invalid
    return result


class Spider:
    def homeContent(self, filter): return contract()


if __name__ == '__main__':
    print(json.dumps(contract(), ensure_ascii=False, indent=2))
