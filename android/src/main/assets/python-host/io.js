// Device-local, bounded in-memory streams. This does not grant filesystem access.
function installPythonIo(library) {
  // Skulpt exposes the legacy IOError name but omits Python 3's OSError.
  if (!Sk.builtins.OSError) {
    Sk.builtins.OSError = Sk.abstr.buildNativeClass('OSError', {
      constructor: function OSError(...args) { Sk.builtin.IOError.apply(this, args); },
      base: Sk.builtin.IOError,
    });
  }
  function nativeModule() {
    const error = Sk.abstr.buildNativeClass('UnsupportedOperation', {
      constructor: function UnsupportedOperation(...args) { Sk.builtin.IOError.apply(this, args); },
      base: Sk.builtins.OSError,
    });
    // These exceptions have identical storage. Skulpt's Python class builder
    // rejects their multiple native bases, so supply the standard exception MRO.
    error.prototype.sk$prototypical = false;
    error.prototype.tp$bases = [Sk.builtins.OSError, Sk.builtin.ValueError];
    error.prototype.tp$mro = [error, Sk.builtins.OSError, Sk.builtin.IOError,
      Sk.builtin.ValueError, Sk.builtin.Exception, Sk.builtin.BaseException, Sk.builtin.object];
    return {UnsupportedOperation:error};
  }
  library['src/lib/_movie_io.js'] = 'var $builtinmodule = ' + nativeModule.toString() + ';';
  library['src/lib/io.py'] = String.raw`
from _movie_io import UnsupportedOperation
SEEK_SET, SEEK_CUR, SEEK_END = 0, 1, 2
_LIMIT = 2 * 1024 * 1024

def _index(value):
    if isinstance(value, int): return value
    if hasattr(value, '__index__'):
        result = value.__index__()
        if isinstance(result, int): return result
    raise TypeError('an integer is required')

class _MemoryStream:
    @property
    def closed(self): return self._closed
    def _check(self):
        if self.closed: raise ValueError('I/O operation on closed file')
    def close(self):
        self._closed = True
        self._data = self._empty
    def flush(self): self._check()
    def readable(self): self._check(); return True
    def writable(self): self._check(); return True
    def seekable(self): self._check(); return True
    def isatty(self): self._check(); return False
    def fileno(self): self._check(); raise UnsupportedOperation('fileno')
    def __enter__(self): self._check(); return self
    def __exit__(self, exc_type, exc, tb): self.close(); return False
    def __iter__(self):
        if self._text: self._check()
        return self
    def __next__(self):
        line = self.readline()
        if not line: raise StopIteration
        return line
    def tell(self): self._check(); return self._position
    def getvalue(self): self._check(); return self._data
    def seek(self, offset, whence=SEEK_SET):
        self._check(); offset, whence = _index(offset), _index(whence)
        if whence not in (SEEK_SET, SEEK_CUR, SEEK_END): raise ValueError('invalid whence')
        if self._text and whence != SEEK_SET and offset != 0:
            raise OSError("Can't do nonzero cur-relative seeks")
        if whence == SEEK_SET:
            if offset < 0: raise ValueError('negative seek position')
            position = offset
        else: position = max(0, (self._position if whence == SEEK_CUR else len(self._data)) + offset)
        self._position = position
        return position
    def read(self, size=-1):
        self._check(); size = -1 if size is None else _index(size)
        start = self._position
        end = len(self._data) if size < 0 else min(len(self._data), start + size)
        self._position = max(start, end)
        return self._data[start:end]
    def readline(self, size=-1):
        self._check(); size = -1 if size is None else _index(size)
        start = self._position
        end = len(self._data) if size < 0 else min(len(self._data), start + size)
        newline = self._data.find(self._newline, start, end)
        if newline >= 0: end = newline + 1
        self._position = max(start, end)
        return self._data[start:end]
    def readlines(self, hint=-1):
        self._check(); hint = -1 if hint is None else _index(hint)
        lines, total = [], 0
        for line in self:
            lines.append(line); total += len(line)
            if hint > 0 and total > hint: break
        return lines
    def write(self, value):
        self._check(); value = self._validate(value)
        size = len(value); start = self._position
        end = start + size
        if end > _LIMIT: raise ValueError('in-memory stream exceeds local size limit')
        if size:
            gap = self._zero * max(0, start - len(self._data))
            self._data = self._data[:start] + gap + value + self._data[end:]
            self._position = end
        return size
    def writelines(self, lines):
        self._check()
        for line in lines: self.write(line)
    def truncate(self, size=None):
        self._check(); size = self._position if size is None else _index(size)
        if size < 0: raise ValueError('negative size value')
        self._data = self._data[:size]
        return size

class StringIO(_MemoryStream):
    _text, _empty, _zero, _newline = True, '', '\x00', '\n'
    encoding, errors, newlines = None, None, None
    def __init__(self, initial_value='', newline='\n'):
        if newline != '\n': raise NotImplementedError('StringIO supports newline="\\n" only')
        initial_value = '' if initial_value is None else self._validate(initial_value)
        if len(initial_value) > _LIMIT: raise ValueError('in-memory stream exceeds local size limit')
        self._data, self._position, self._closed = initial_value, 0, False
    def _validate(self, value):
        if not isinstance(value, str): raise TypeError('string argument expected')
        return value

class BytesIO(_MemoryStream):
    _text, _empty, _zero, _newline = False, b'', b'\x00', b'\n'
    def __init__(self, initial_bytes=b''):
        initial_bytes = b'' if initial_bytes is None else self._validate(initial_bytes)
        if len(initial_bytes) > _LIMIT: raise ValueError('in-memory stream exceeds local size limit')
        self._data, self._position, self._closed = initial_bytes, 0, False
    def _validate(self, value):
        if not isinstance(value, bytes): raise TypeError('a bytes object is required')
        return value
    def read1(self, size=-1): return self.read(size)
    def getbuffer(self): self._check(); raise UnsupportedOperation('mutable buffer views are unavailable')
    def readinto(self, buffer): self._check(); raise UnsupportedOperation('mutable buffer writes are unavailable')
    def readinto1(self, buffer): return self.readinto(buffer)
`;
}

// A source-local, read-only virtual package. No callbacks or host paths are used.
function installPythonPackage(library, packageData) {
  const root = '/__package__/', perFile = 2 * 1024 * 1024, totalLimit = 6 * 1024 * 1024;
  const resources = Object.create(null);
  let entry = '', total = 0;
  const safeName = name => typeof name === 'string' && name.length > 0 && name.length <= 512 &&
    !name.startsWith('/') && !/[\\:'"\x00-\x1f\x7f\u2028\u2029]/.test(name) &&
    name.split('/').every(part => part && part !== '.' && part !== '..');
  if (packageData != null) {
    if (typeof packageData !== 'object' || Array.isArray(packageData) ||
        !safeName(packageData.entry) || !packageData.files ||
        typeof packageData.files !== 'object' || Array.isArray(packageData.files)) {
      throw new Error('Python package requires a safe entry and local base64 files');
    }
    entry = packageData.entry;
    const names = Object.keys(packageData.files);
    if (names.length > 256) throw new Error('Python package exceeds 256 files');
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    for (const name of names) {
      if (!safeName(name)) throw new Error('Invalid Python package file path');
      const value = packageData.files[name];
      if (typeof value !== 'string' || value.length > Math.ceil(perFile / 3) * 4 ||
          value.length % 4 !== 0 || /[^A-Za-z0-9+/=]/.test(value)) {
        throw new Error('Invalid or oversized Python package file');
      }
      const pad = value.endsWith('==') ? 2 : value.endsWith('=') ? 1 : 0;
      const body = value.slice(0, value.length - pad);
      if (body.includes('=') || pad && (body.length < 2 ||
          (alphabet.indexOf(body[body.length - 1]) & (pad === 2 ? 15 : 3)) !== 0)) {
        throw new Error('Invalid Python package base64');
      }
      const bytes = value.length / 4 * 3 - pad;
      if (bytes > perFile || (total += bytes) > totalLimit) throw new Error('Python package exceeds byte limit');
      resources[name] = value;
    }
    if (!Object.prototype.hasOwnProperty.call(resources, entry)) throw new Error('Python package entry is missing');
    for (const name of names) {
      const parts = name.split('/');
      parts.pop();
      while (parts.length) {
        if (Object.prototype.hasOwnProperty.call(resources, parts.join('/'))) throw new Error('Python package file conflicts with a directory');
        parts.pop();
      }
    }
  }
  for (const name of ['FileNotFoundError', 'PermissionError', 'IsADirectoryError']) {
    if (!Sk.builtins[name]) {
      Sk.builtins[name] = Sk.abstr.buildNativeClass(name, {
        constructor: function (...args) { Sk.builtin.IOError.apply(this, args); },
        base: Sk.builtins.OSError,
      });
    }
  }
  const directory = entry.includes('/') ? entry.substring(0, entry.lastIndexOf('/') + 1) : '';
  function packageModule(bundle) {
    const resources = bundle.files, root = '/__package__/';
    function read(value) {
      if (!(value instanceof Sk.builtin.str)) throw new Sk.builtin.TypeError('package filename must be a string');
      const path = value.v;
      if (!path || path.length > 1024 || /[\\:\x00-\x1f\x7f]/.test(path)) throw new Sk.builtin.ValueError('invalid package path');
      let relative;
      if (path.startsWith(root)) relative = path.substring(root.length);
      else if (path.startsWith('/')) throw new Sk.builtins.PermissionError('only local package files may be opened');
      else relative = bundle.directory + path;
      const parts = [];
      for (const part of relative.split('/')) {
        if (!part || part === '.') continue;
        if (part === '..') {
          if (!parts.length) throw new Sk.builtins.PermissionError('package path escapes its root');
          parts.pop();
        } else parts.push(part);
      }
      const key = parts.join('/');
      if (!Object.prototype.hasOwnProperty.call(resources, key)) {
        if (!key || Object.keys(resources).some(name => name.startsWith(key + '/'))) throw new Sk.builtins.IsADirectoryError('package path is a directory');
        throw new Sk.builtins.FileNotFoundError('package file not found: ' + key);
      }
      const text = resources[key], alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      const padding = text.endsWith('==') ? 2 : text.endsWith('=') ? 1 : 0;
      const output = new Uint8Array(text.length / 4 * 3 - padding);
      let bits = 0, count = 0, offset = 0;
      for (const char of text) {
        if (char === '=') break;
        bits = (bits << 6) | alphabet.indexOf(char); count += 6;
        if (count >= 8) { count -= 8; output[offset++] = (bits >>> count) & 255; }
      }
      return new Sk.builtin.bytes(output);
    }
    return {read: new Sk.builtin.func(read)};
  }
  library['src/lib/_movie_package.js'] = 'var $builtinmodule = function() { return (' +
    packageModule.toString() + ')(JSON.parse(' + JSON.stringify(JSON.stringify({directory, files:resources})) + ')); };';
  library['src/lib/io.py'] += String.raw`

class _PackageReadOnly:
    def writable(self): self._check(); return False
    def __iter__(self): self._check(); return self
    def write(self, value):
        if self._text: self._check()
        raise UnsupportedOperation('not writable')
    def writelines(self, lines):
        self._check()
        for line in lines: self.write(line)
    def truncate(self, size=None): self._check(); raise UnsupportedOperation('not writable')

class _PackageBinary(_PackageReadOnly, BytesIO):
    def __init__(self, data, name):
        BytesIO.__init__(self, data)
        self.name, self.mode = name, 'rb'
    def seek(self, offset, whence=SEEK_SET):
        self._check(); offset, whence = _index(offset), _index(whence)
        if whence not in (SEEK_SET, SEEK_CUR, SEEK_END): raise ValueError('invalid whence')
        position = offset + (self._position if whence == SEEK_CUR else len(self._data) if whence == SEEK_END else 0)
        if position < 0:
            if whence == SEEK_SET: raise ValueError('negative seek position')
            raise OSError('negative seek position')
        self._position = position
        return position

class _PackageText(_PackageReadOnly, _MemoryStream):
    _text, _empty = True, ''
    def __init__(self, data, name, mode, encoding, newline):
        self._raw, self._position, self._closed = data, 0, False
        self._tail, self._cursor, self._seen = None, 0, []
        self.name, self.mode, self.encoding, self.errors = name, mode, encoding, 'strict'
        self._translation = newline
    @property
    def newlines(self):
        kinds = [v for v in ('\r', '\n', '\r\n') if v in self._seen]
        return None if not kinds else kinds[0] if len(kinds) == 1 else tuple(kinds)
    def close(self):
        self._closed, self._raw, self._tail = True, b'', None
    def _ensure(self):
        if self._tail is None:
            self._tail = self._raw[self._position:].decode('utf-8', 'strict')
            if self.encoding == 'utf-8-sig' and self._position == 0 and self._tail.startswith('\ufeff'):
                self._tail = self._tail[1:]; self._position = 3
            self._cursor = 0
            if self._translation in (None, ''):
                bare = self._tail.replace('\r\n', '')
                for value, present in [('\r\n','\r\n' in self._tail), ('\r','\r' in bare), ('\n','\n' in bare)]:
                    if present and value not in self._seen: self._seen.append(value)
    def _read_text(self, size, line):
        self._check(); size = -1 if size is None else _index(size)
        if size == 0: return ''
        self._ensure()
        rest = self._tail[self._cursor:]
        end = len(rest)
        if line:
            terminators = ('\r', '\n') if self._translation in (None, '') else (self._translation,)
            ends = []
            for terminator in terminators:
                found = rest.find(terminator)
                if found >= 0:
                    length = 2 if self._translation in (None, '') and rest[found:found+2] == '\r\n' else len(terminator)
                    ends.append(found + length)
            if ends: end = min(ends)
        if size >= 0:
            if self._translation is None:
                visible = rest[:end].replace('\r\n','\n').replace('\r','\n')
                if size < len(visible):
                    count, limit = 0, 0
                    while count < size:
                        limit += 2 if rest[limit:limit+2] == '\r\n' else 1
                        count += 1
                    end = limit
            else: end = min(end, size)
        consumed = rest[:end]
        self._cursor += end
        self._position += len(consumed.encode('utf-8'))
        return consumed.replace('\r\n','\n').replace('\r','\n') if self._translation is None else consumed
    def read(self, size=-1): return self._read_text(size, False)
    def readline(self, size=-1): return self._read_text(size, True)
    def seek(self, offset, whence=SEEK_SET):
        self._check(); offset, whence = _index(offset), _index(whence)
        if whence not in (SEEK_SET, SEEK_CUR, SEEK_END): raise ValueError('invalid whence')
        if whence != SEEK_SET and offset != 0: raise UnsupportedOperation("can't do nonzero relative text seeks")
        if offset < 0: raise ValueError('negative seek position')
        self._position = self._position if whence == SEEK_CUR else len(self._raw) if whence == SEEK_END else offset
        self._tail, self._cursor = None, 0
        if self._position == 0: self._seen = []
        return self._position
    def getvalue(self): raise UnsupportedOperation('file streams do not expose getvalue')

def open(file, mode='r', buffering=-1, encoding=None, errors=None, newline=None, closefd=True, opener=None):
    from _movie_package import read
    if not isinstance(file, str): raise TypeError('package filename must be a string')
    if not isinstance(mode, str): raise TypeError('mode must be a string')
    if not mode or len(set(mode)) != len(mode) or any(c not in 'rwaxbt+' for c in mode) or sum(c in mode for c in 'rwax') != 1 or ('b' in mode and 't' in mode):
        raise ValueError('invalid file mode')
    if 'r' not in mode or '+' in mode: raise UnsupportedOperation('package files are read-only')
    buffering = _index(buffering)
    if buffering < -1: raise ValueError('invalid buffering size')
    if not closefd: raise ValueError('cannot use closefd=False with a filename')
    if opener is not None: raise UnsupportedOperation('custom file openers are unavailable')
    if 'b' in mode:
        if encoding is not None or errors is not None or newline is not None: raise ValueError('binary mode does not take text options')
        return _PackageBinary(read(file), file)
    if buffering == 0: raise ValueError('unbuffered text I/O is unavailable')
    if encoding is None: encoding = 'utf-8'
    if not isinstance(encoding, str): raise TypeError('encoding must be a string')
    encoding = encoding.lower().replace('_','-')
    if encoding == 'utf8': encoding = 'utf-8'
    if encoding not in ('utf-8', 'utf-8-sig'): raise NotImplementedError('package text files support UTF-8 only')
    if errors not in (None, 'strict'): raise NotImplementedError('package text files support strict decoding only')
    if newline not in (None, '', '\n', '\r', '\r\n'): raise ValueError('illegal newline value')
    return _PackageText(read(file), file, mode, encoding, newline)
`;
  return {
    activate() {
      const original = Sk.__movieOriginalCompile || Sk.compile;
      if (!Sk.__movieOriginalCompile) Sk.__movieOriginalCompile = original;
      Sk.compile = function(code, filename, mode, canSuspend) {
        let mapped = filename;
        if (entry && filename === '<source>.py') mapped = root + entry;
        else if (entry && filename.startsWith('src/lib/')) {
          const relative = directory + filename.substring('src/lib/'.length);
          if (Object.prototype.hasOwnProperty.call(resources, relative)) mapped = root + relative;
        }
        return original(code, mapped, mode, canSuspend);
      };
      function open(file, mode, buffering, encoding, errors, newline, closefd, opener) {
        const args = Array.from(arguments);
        return Sk.misceval.chain(Sk.importModule('io', false, true), module =>
          Sk.misceval.callsimOrSuspendArray(module.$d.open, args));
      }
      open.co_varnames = ['file','mode','buffering','encoding','errors','newline','closefd','opener'];
      open.$defaults = [new Sk.builtin.str('r'),new Sk.builtin.int_(-1),Sk.builtin.none.none$,
        Sk.builtin.none.none$,Sk.builtin.none.none$,Sk.builtin.bool.true$,Sk.builtin.none.none$];
      Sk.builtins.open = new Sk.builtin.func(open);
    },
  };
}
