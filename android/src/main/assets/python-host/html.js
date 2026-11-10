// Read-only BeautifulSoup operations used by local Python catalogue scripts.
// The bundled Cheerio parser is created lazily, only when bs4 is imported. DOM
// nodes belong to Python objects; no global node registry survives a source.
function installPythonHtml(library) {
  function nativeModule() {
    const parser = __moviePythonHtmlParser();
    const maxMarkup = 2 * 1024 * 1024, maxNodes = 50000, maxMatches = 10000;
    const string = value => {
      if (!Sk.builtin.checkString(value)) throw new Sk.builtin.TypeError('HTML and selectors require str');
      return value.v;
    };
    const wrap = selection => {
      const handle = new Sk.builtin.object();
      handle.$movieHtml = selection;
      return handle;
    };
    const selected = handle => {
      if (!handle || !handle.$movieHtml) throw new Sk.builtin.TypeError('Invalid HTML node');
      return handle.$movieHtml;
    };
    // Iterative traversal also handles deeply nested (but bounded) documents.
    const walk = (roots, visit) => {
      const stack = Array.from(roots).reverse();
      let count = 0;
      while (stack.length) {
        const node = stack.pop();
        if (++count > maxNodes) throw new Sk.builtin.ValueError('HTML document exceeds 50000 nodes');
        if (visit(node) === false) continue;
        const children = node.children || [];
        for (let i = children.length - 1; i >= 0; i--) stack.push(children[i]);
      }
    };
    return {
      parse: new Sk.builtin.func(function (markup) {
        Sk.builtin.pyCheckArgsLen('parse', arguments.length, 1, 1);
        const html = string(markup);
        if (html.length > maxMarkup) throw new Sk.builtin.ValueError('HTML markup exceeds 2 Mi characters');
        const root = parser.load(html, {xml: {xmlMode: false, decodeEntities: true}}, false).root();
        walk(root.toArray(), () => {});
        return wrap(root);
      }),
      select: new Sk.builtin.func(function (handle, selector, first) {
        Sk.builtin.pyCheckArgsLen('select', arguments.length, 3, 3);
        const root = selected(handle), css = string(selector);
        if (!css.trim() || css.length > 2048) throw new Sk.builtin.ValueError('CSS selector must contain 1 to 2048 characters');
        let matches;
        try { matches = root.find(css); }
        catch (error) { throw new Sk.builtin.ValueError('Invalid or unsupported CSS selector: ' + error.message); }
        if (Sk.misceval.isTrue(first)) return matches.length ? wrap(matches.eq(0)) : Sk.builtin.none.none$;
        if (matches.length > maxMatches) throw new Sk.builtin.ValueError('HTML selection exceeds 10000 nodes');
        return new Sk.builtin.list(matches.toArray().map((_, index) => wrap(matches.eq(index))));
      }),
      attr: new Sk.builtin.func(function (handle, name, fallback) {
        Sk.builtin.pyCheckArgsLen('attr', arguments.length, 3, 3);
        const node = selected(handle)[0], key = string(name);
        const value = node && node.attribs && Object.prototype.hasOwnProperty.call(node.attribs, key) ? node.attribs[key] : undefined;
        if (value === undefined) return fallback;
        if (key === 'class' || key === 'accesskey' || key === 'dropzone' ||
            (['a', 'link', 'area'].includes(node.name) && ['rel', 'rev'].includes(key)) ||
            (['td', 'th'].includes(node.name) && key === 'headers') ||
            (node.name === 'form' && key === 'accept-charset') ||
            (node.name === 'output' && key === 'for')) {
          return Sk.ffi.remapToPy(value.trim().split(/\s+/).filter(Boolean));
        }
        return new Sk.builtin.str(value);
      }),
      strings: new Sk.builtin.func(function (handle) {
        Sk.builtin.pyCheckArgsLen('strings', arguments.length, 1, 1);
        const output = [];
        const special = ['script', 'style', 'template', 'rt', 'rp'];
        for (const root of selected(handle).toArray()) {
          const expected = special.includes(root.name) ? root.name : null;
          let parent = root, inherited = null;
          while (parent) {
            if (special.includes(parent.name)) { inherited = parent.name; break; }
            parent = parent.parent;
          }
          if (inherited !== expected) continue;
          walk([root], node => {
            if (node.type === 'comment' || (special.includes(node.name) && node.name !== expected)) return false;
            if (node.type === 'text') output.push(new Sk.builtin.str(node.data));
          });
        }
        return new Sk.builtin.list(output);
      })
    };
  }
  library['src/lib/_movie_html.js'] = 'var $builtinmodule = ' + nativeModule.toString() + ';';
  library['src/lib/bs4/__init__.py'] = `import _movie_html
class Tag:
    def __init__(self, handle): self._handle = handle
    def select(self, selector): return [Tag(handle) for handle in _movie_html.select(self._handle, selector, False)]
    def select_one(self, selector):
        handle = _movie_html.select(self._handle, selector, True)
        return None if handle is None else Tag(handle)
    def get(self, name, default=None): return _movie_html.attr(self._handle, name, default)
    def get_text(self, separator='', strip=False):
        if not isinstance(separator, str): raise TypeError('separator must be str')
        values = _movie_html.strings(self._handle)
        if strip: values = [value.strip() for value in values if value.strip()]
        return separator.join(values)
    @property
    def text(self): return self.get_text()
class BeautifulSoup(Tag):
    def __init__(self, markup, features='html.parser'):
        if features not in (None, 'html.parser'): raise NotImplementedError('Only html.parser is available in this local HTML adapter')
        self._handle = _movie_html.parse(markup)
`;
}
