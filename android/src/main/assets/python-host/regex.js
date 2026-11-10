// Extend the bundled interpreter's existing re module without modifying its
// upstream asset. Substitution is intentionally bounded and rejects unsupported
// Python-only syntax, callable replacements and zero-width matches explicitly.
function installPythonRegex(library) {
  function extend(mod) {
    const white = '\\t\\n\\v\\f\\r\\x1c-\\x1f \\x85\\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000';
    function substitute(pattern, replacement, input, count, flags, pair) {
      if (!Sk.builtin.checkString(pattern) || !Sk.builtin.checkString(replacement) || !Sk.builtin.checkString(input)) {
        throw new Sk.builtin.TypeError('sub requires string pattern, replacement and input');
      }
      if (!Sk.builtin.checkInt(count) || !Sk.builtin.checkInt(flags)) throw new Sk.builtin.TypeError('count and flags must be integers');
      count = Sk.builtin.asnum$(count); flags = Sk.builtin.asnum$(flags);
      if (!Number.isSafeInteger(count)) throw new Sk.builtin.OverflowError('count is too large');
      if ((flags & ~(2 | 8 | 32 | 256)) || !Number.isSafeInteger(flags) || flags < 0 || flags > 511 || ((flags & 32) && (flags & 256))) {
        throw new Sk.builtin.NotImplementedError('sub supports only IGNORECASE, MULTILINE, Unicode or ASCII flags');
      }
      if (pattern.v.length > 2048 || input.v.length > 2 * 1024 * 1024 || replacement.v.length > 65536) throw new Sk.builtin.ValueError('regular expression substitution exceeds local limits');
      const ascii = !!(flags & 256), classes = {s: ascii ? '\\t\\n\\v\\f\\r ' : white,
        d: ascii ? '0-9' : '\\p{Decimal_Number}', w: ascii ? 'A-Za-z0-9_' : '\\p{L}\\p{N}_'};
      let source = '', bracket = false;
      for (let i = 0; i < pattern.v.length; i++) {
        let c = pattern.v[i];
        if (c === '\\') {
          const escaped = pattern.v[++i];
          if (escaped === undefined) throw new Sk.builtin.ValueError('trailing pattern escape');
          const lower = escaped.toLowerCase();
          if (Object.prototype.hasOwnProperty.call(classes, lower)) {
            const negative = escaped !== lower;
            if (bracket && negative) throw new Sk.builtin.NotImplementedError('negative shorthand inside a character class is unavailable');
            source += bracket ? classes[lower] : '[' + (negative ? '^' : '') + classes[lower] + ']';
          } else if (/[A-Za-z]/.test(escaped) && !'nrtfvxu'.includes(escaped)) {
            throw new Sk.builtin.NotImplementedError('unsupported Python pattern escape: \\' + escaped);
          } else source += '\\' + escaped;
        } else {
          if (c === '[') bracket = true;
          if (c === ']') bracket = false;
          if (c === '(' && pattern.v[i + 1] === '?' && ![':', '=', '!'].includes(pattern.v[i + 2])) throw new Sk.builtin.NotImplementedError('unsupported Python group syntax');
          source += c;
        }
      }
      const mode = 'u' + (flags & 2 ? 'i' : '') + (flags & 8 ? 'm' : '');
      let regex, groups;
      try {
        regex = new RegExp(source, 'g' + mode);
        groups = new RegExp('(?:' + source + ')|', mode).exec('').length - 1;
      } catch (_) { throw new Sk.builtin.ValueError('invalid regular expression'); }
      const parts = [], escapes = {n:'\n', r:'\r', t:'\t', f:'\f', v:'\v', a:'\x07', b:'\b', '\\':'\\'};
      for (let i = 0; i < replacement.v.length; i++) {
        let c = replacement.v[i];
        if (c !== '\\') { parts.push(c); continue; }
        c = replacement.v[++i];
        if (c === undefined) throw new Sk.builtin.ValueError('trailing replacement escape');
        if (Object.prototype.hasOwnProperty.call(escapes, c)) { parts.push(escapes[c]); continue; }
        if (c === '0' || (/[0-7]/.test(c) && /^[0-7]{2}/.test(replacement.v.slice(i + 1)))) {
          const octal = (c + replacement.v.slice(i + 1)).match(/^[0-7]{1,3}/)[0];
          const value = parseInt(octal, 8);
          if (value > 255) throw new Sk.builtin.ValueError('octal replacement escape out of range');
          parts.push(String.fromCharCode(value)); i += octal.length - 1; continue;
        }
        let group;
        if (/[1-9]/.test(c)) {
          const digits = (c + replacement.v.slice(i + 1)).match(/^[1-9][0-9]?/)[0];
          group = Number(digits); i += digits.length - 1;
        } else if (c === 'g') {
          const reference = replacement.v.slice(i + 1).match(/^<([0-9]+)>/);
          if (!reference) throw new Sk.builtin.NotImplementedError('only numeric replacement group references are available');
          group = Number(reference[1]); i += reference[0].length;
        } else if (/[A-Za-z]/.test(c)) throw new Sk.builtin.ValueError('invalid replacement escape');
        else { parts.push('\\' + c); continue; }
        if (!Number.isSafeInteger(group) || group > groups) throw new Sk.builtin.ValueError('invalid replacement group reference');
        parts.push({group});
      }
      const output = []; let last = 0, replaced = 0, match, size = 0;
      const append = text => {
        size += text.length;
        if (size > 2 * 1024 * 1024) throw new Sk.builtin.ValueError('substitution output exceeds local limits');
        output.push(text);
      };
      while (count >= 0 && (count === 0 || replaced < count) && (match = regex.exec(input.v)) !== null) {
        if (!match[0].length) throw new Sk.builtin.NotImplementedError('zero-width substitution is unavailable in this adapter');
        append(input.v.slice(last, match.index));
        append(parts.map(part => typeof part === 'string' ? part : match[part.group] || '').join(''));
        last = regex.lastIndex; replaced++;
        if (replaced > 100000) throw new Sk.builtin.ValueError('substitution exceeds 100000 matches');
      }
      append(input.v.slice(last));
      const value = new Sk.builtin.str(output.join(''));
      return pair ? new Sk.builtin.tuple([value, new Sk.builtin.int_(replaced)]) : value;
    }
    for (const name of ['sub', 'subn']) {
      const invoke = function(pattern, repl, string, count, flags) {
        Sk.builtin.pyCheckArgsLen(name, arguments.length, 3, 5);
        return substitute(pattern, repl, string, count, flags, name === 'subn');
      };
      invoke.co_varnames = ['pattern', 'repl', 'string', 'count', 'flags'];
      invoke.$defaults = [new Sk.builtin.int_(0), new Sk.builtin.int_(0)];
      mod[name] = new Sk.builtin.func(invoke);
    }
    return mod;
  }
  library['src/lib/re.js'] += '\n(function(original){$builtinmodule=function(name){return (' + extend.toString() + ')(original(name));};})($builtinmodule);';
}
