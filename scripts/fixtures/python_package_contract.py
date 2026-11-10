"""Self-authored read-only package cases; the expected results come from CPython."""
import io
import json
from helper import title, helper_location
from tools.reader import local, reader_location

ROOT = __file__.replace('\\', '/').rsplit('/', 1)[0]


def contract():
    result = {}
    result['module_locations'] = [__file__.replace('\\', '/').endswith('/bundle/main.py'), helper_location, reader_location]
    result['module_data'] = [title, local]
    with open('data/metadata.json', encoding='UTF_8') as stream:
        result['json_data'] = json.load(stream)
        result['text_capabilities'] = [stream.readable(), stream.writable(), stream.seekable(), stream.isatty(), stream.flush()]
    result['context_closed'] = stream.closed
    result['relative_parent'] = open('../shared.txt', encoding='utf8').read()
    result['unicode_filename'] = io.open('data/中文 空格.txt', encoding='utf-8').read()
    result['default_text'] = open('data/ascii.txt').read()
    result['normalized_relative'] = open('./data/../data/ascii.txt').read()
    result['absolute_from_file'] = open(ROOT + '/data/ascii.txt').read()
    result['main_code_read'] = open(__file__, encoding='utf-8').read().startswith('"""Self-authored')

    binary = io.open('data/payload.bin', 'rb')
    result['binary_read'] = [list(binary.read(2)), binary.tell(), list(binary.readline()), list(binary.read1(1)), list(binary.read())]
    binary.seek(0)
    result['binary_iteration'] = [list(line) for line in binary]
    result['binary_seek'] = [binary.seek(-2, 2), list(binary.read()), binary.seek(1), list(binary.read(1)), binary.seek(20), list(binary.read())]
    binary.seek(0)
    result['binary_readlines'] = [list(line) for line in binary.readlines(2)]
    result['binary_capabilities'] = [binary.readable(), binary.writable(), binary.seekable(), binary.isatty(), binary.flush(), binary.mode, binary.name]
    result['empty_binary'] = [list(open('data/empty.bin', 'rb').read()), list(open('data/empty.bin', 'rb'))]
    binary.close()
    result['binary_closed'] = binary.closed

    for name, newline in [('universal', None), ('preserved', ''), ('lf', '\n'), ('cr', '\r'), ('crlf', '\r\n')]:
        text = open('data/lines.txt', encoding='utf-8', newline=newline)
        result['lines_' + name] = list(text)
        text.seek(0)
        result['read_' + name] = text.read()
        text.seek(0)
        result['partial_' + name] = [text.read(2), text.readline(1), text.readline(), text.read(None)]
        text.seek(0)
        result['newlines_' + name] = text.newlines
        text.read()
        result['seen_newlines_' + name] = text.newlines
        text.seek(0)
        text.readline()
        position = text.tell()
        tail = text.read()
        text.seek(position)
        result['text_cookie_' + name] = text.read() == tail
        result['text_end_' + name] = [text.seek(0, 2), text.read(), text.seek(0, 1)]
        text.close()

    text = open('data/utf8.txt', encoding='utf-8')
    result['utf8_positions'] = [text.read(1), text.tell(), text.read(1), text.tell(), text.readline(), text.tell()]
    text.seek(0)
    result['text_size_zero'] = [text.read(0), text.tell(), text.readline(0), text.tell()]
    result['text_hint'] = text.readlines(2)
    result['utf8_bom'] = open('data/bom.txt', encoding='utf-8').read()
    bom = open('data/bom.txt', encoding='utf-8-sig')
    result['bom_read_zero'] = [bom.read(0), bom.tell()]
    result['bom_text'] = [bom.read(1), bom.tell(), bom.read(), bom.tell()]
    bom.seek(0)
    result['bom_rewind'] = bom.read()
    result['bom_empty'] = open('data/empty.bin', encoding='utf-8-sig').read()

    errors = []
    for action in [lambda: binary.read(), lambda: binary.seek(0), lambda: iter(binary),
                   lambda: open('missing.txt'),
                   lambda: open('data/ascii.txt', 'rb', encoding='utf-8'),
                   lambda: open('data/ascii.txt', 'rtb'), lambda: open('data/ascii.txt', ''),
                   lambda: open('data/ascii.txt', buffering=0), lambda: open('data/ascii.txt', closefd=False),
                   lambda: open('data/invalid.bin', encoding='utf-8').read(),
                   lambda: text.seek(1, 1), lambda: text.seek(-1), lambda: text.read(1.5),
                   lambda: open('data/payload.bin', 'rb').seek(-20, 1),
                   lambda: open('data/ascii.txt').write('x'),
                   lambda: open('data/ascii.txt').truncate(),
                   lambda: open('data/ascii.txt').fileno()]:
        try:
            value = action()
            if isinstance(value, int): value = 'descriptor'
            errors.append(['ok', value])
        except Exception as error:
            errors.append(type(error).__name__)
    # A real file has a descriptor while the package intentionally does not.
    result['portable_errors'] = errors[:-1]
    # CPython reports PermissionError on Windows and IsADirectoryError on POSIX.
    try:
        open('data')
        result['directory_is_os_error'] = False
    except OSError:
        result['directory_is_os_error'] = True
    readonly = open('data/ascii.txt')
    result['empty_writelines'] = readonly.writelines([])
    try:
        with open('data/ascii.txt') as owned:
            raise RuntimeError('propagated')
    except RuntimeError as error:
        result['context_exception'] = [str(error), owned.closed]
    return result


class Spider:
    def homeContent(self, filter): return contract()


if __name__ == '__main__':
    print(json.dumps(contract(), ensure_ascii=False, indent=2))
