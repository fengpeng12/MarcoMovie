"""Self-authored in-memory stream cases; CPython supplies the oracle."""
import io
import json


def contract():
    result = {}
    text = io.StringIO('中文🎬\nsecond\r\nend')
    result['text_read'] = [text.read(2), text.tell(), text.readline(), text.readline(3), text.read(None)]
    text.seek(0)
    result['iteration'] = list(text)
    text.seek(0)
    result['readlines_hint'] = [text.readlines(4), text.readlines()]
    text.seek(1)
    result['text_write'] = [text.write('甲'), text.getvalue(), text.tell()]
    text.seek(20)
    result['text_empty_write'] = [text.write(''), len(text.getvalue()), text.tell()]
    result['text_hole'] = [text.write('Z'), text.getvalue(), text.tell()]
    result['text_truncate'] = [text.truncate(2), text.getvalue(), text.tell(), text.truncate(30), text.getvalue()]
    result['text_seek_end'] = [text.seek(0, io.SEEK_END), text.read(), text.seek(0, io.SEEK_CUR)]
    result['text_capabilities'] = [text.readable(), text.writable(), text.seekable(), text.isatty(), text.flush(), text.encoding, text.errors, text.newlines]
    result['text_initial_none'] = io.StringIO(None).getvalue()
    result['binary_initial_none'] = list(io.BytesIO(None).getvalue())
    binary = io.BytesIO(bytes([0, 255, 10, 128, 65, 10, 66]))
    result['binary_read'] = [list(binary.read(2)), binary.tell(), list(binary.readline()), list(binary.read1(2)), list(binary.read())]
    binary.seek(0)
    result['binary_lines'] = [list(v) for v in binary]
    binary.seek(1)
    result['binary_overwrite'] = [binary.write(b'XY'), list(binary.getvalue())]
    binary.seek(12)
    result['binary_empty_write'] = [binary.write(b''), list(binary.getvalue()), binary.tell()]
    result['binary_hole'] = [binary.write(b'Z'), list(binary.getvalue()), binary.tell()]
    result['binary_seek'] = [binary.seek(-2, io.SEEK_CUR), binary.seek(-20, io.SEEK_CUR), binary.seek(-1, io.SEEK_END), list(binary.read())]
    result['binary_truncate'] = [binary.truncate(1), list(binary.getvalue()), binary.tell(), binary.truncate(30), list(binary.getvalue())]
    lines = io.StringIO()
    result['writelines_return'] = lines.writelines(['一\n', '二\n'])
    result['writelines_text'] = lines.getvalue()
    stream = io.StringIO()
    json.dump({'id': 9007199254740993123456789, 'title': '中文🎬'}, stream, ensure_ascii=False)
    result['json_stream_text'] = stream.getvalue()
    stream.seek(0)
    value = json.load(stream)
    result['json_stream_value'] = [str(value['id']), value['title']]
    with io.BytesIO(b'ABC') as owned:
        result['context_read'] = list(owned.read())
    result['closed'] = owned.closed
    closed_text = io.StringIO(); closed_text.close()
    errors = []
    for action in [lambda: owned.read(), lambda: owned.getvalue(), lambda: owned.seek(0),
                   lambda: owned.write(b'X'), lambda: owned.flush(), lambda: iter(owned),
                   lambda: iter(closed_text), lambda: next(owned),
                   lambda: io.StringIO(b'x'), lambda: io.BytesIO('x'),
                   lambda: text.write(b'x'), lambda: binary.write('x'),
                   lambda: text.seek(1, 1), lambda: text.seek(-1),
                   lambda: binary.seek(0, 3), lambda: binary.read(1.5),
                   lambda: text.truncate(-1), lambda: text.fileno()]:
        try: action()
        except (ValueError, TypeError, OSError) as error: errors.append(type(error).__name__)
    result['errors'] = errors
    unsupported = io.UnsupportedOperation('no descriptor')
    result['exception_bases'] = [isinstance(unsupported, OSError), isinstance(unsupported, ValueError), issubclass(io.UnsupportedOperation, OSError), issubclass(io.UnsupportedOperation, ValueError)]
    try: owned.closed = False
    except AttributeError: result['closed_readonly'] = True
    owned.close()
    result['close_idempotent'] = owned.closed
    try:
        with io.StringIO() as context:
            raise RuntimeError('preserve exception')
    except RuntimeError as error:
        result['context_exception'] = [str(error), context.closed]
    return result


class Spider:
    def homeContent(self, filter): return contract()


if __name__ == '__main__':
    print(json.dumps(contract(), ensure_ascii=False, indent=2))
