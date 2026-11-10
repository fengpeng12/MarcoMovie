// Shared module boundary for local user scripts. No built-in sources or Node APIs.
globalThis.__movieLoadCommonJS = function(entry, load) {
  const cache = Object.create(null);
  function requireFrom(reference, parent) {
    if (typeof reference !== 'string') throw new Error('require() expects a static module name');
    const record = load(reference, parent);
    if (!record || typeof record.name !== 'string' || typeof record.source !== 'string')
      throw new Error('Script dependency is unavailable: ' + reference);
    if (cache[record.name]) return cache[record.name].exports;
    const module = {exports: {}};
    cache[record.name] = module;
    try {
      if (/\.json(?:[?#].*)?$/.test(record.name)) {
        module.exports = JSON.parse(record.source);
      } else {
        const directory = record.name.substring(0, record.name.lastIndexOf('/'));
        const code = record.source.replace(/^#![^\n]*(?:\n|$)/, '');
        const run = new Function('module', 'exports', 'require', '__filename', '__dirname', code);
        run.call(module.exports, module, module.exports,
          function(name) { return requireFrom(name, record.name); }, record.name, directory);
      }
      return module.exports;
    } catch (error) {
      delete cache[record.name];
      throw error;
    }
  }
  return requireFrom(entry, entry);
};
globalThis.__movieSelectSpider = function(module, options = {}) {
  let spider = module && module.default != null ? module.default : module;
  if (!spider || (typeof spider !== 'object' && typeof spider !== 'function'))
    throw new Error('Script has no Spider export');
  const aliases = {
    home: ['homeContent', args => args],
    homeVod: ['homeVideoContent', args => args],
    category: ['categoryContent', args => [args[0], String(args[1] == null ? 1 : args[1]), args[2], args[3]]],
    detail: ['detailContent', args => [Array.isArray(args[0]) ? args[0] : [args[0]]]],
    search: ['searchContent', args => [args[0], args[1], String(args[2] == null ? 1 : args[2])]],
    play: ['playerContent', args => args]
  };
  const shortNames = Object.keys(aliases);
  const longNames = shortNames.map(name => aliases[name][0]);
  const methods = [...shortNames, ...longNames, 'init', 'proxy', 'action',
    'getRule', 'liveContent', 'manualVideoCheck', 'isVideoFormat', 'destroy'];
  // Preserve legacy function objects with static entrypoints. Exported classes
  // (including inherited methods/private fields) get one instance per selection.
  if (typeof spider === 'function' &&
      !methods.some(name => typeof spider[name] === 'function') &&
      (/^\s*class\b/.test(Function.prototype.toString.call(spider)) ||
       (spider.prototype && methods.some(name => typeof spider.prototype[name] === 'function')))) {
    spider = new spider();
  }
  if (spider && typeof spider.then === 'function')
    throw new TypeError('Spider constructor must be synchronous');
  const fullOnly = !shortNames.some(name => typeof spider[name] === 'function') &&
    [...longNames, 'liveContent'].some(name => typeof spider[name] === 'function');
  const missing = shortNames.filter(name => spider[name] == null &&
    typeof spider[aliases[name][0]] === 'function');
  if (!missing.length && !(fullOnly && !options.preserveInit &&
      typeof spider.init === 'function')) return spider;
  // Never mutate an ES-module namespace or a frozen source export. Bind every
  // public entry to the original instance so source state and private fields work.
  const facade = Object.create(spider);
  for (const name of methods) {
    if (typeof spider[name] !== 'function') continue;
    Object.defineProperty(facade, name, {value: function(...args) {
      if (name === 'init' && fullOnly && !options.preserveInit) {
        const ext = typeof options.rawExtension === 'string'
          ? options.rawExtension : args[0];
        args[0] = typeof ext === 'string' ? ext : ext == null ? '' : JSON.stringify(ext);
      }
      return spider[name].apply(spider, args);
    }, enumerable: true});
  }
  for (const name of missing) {
    const [target, adapt] = aliases[name];
    Object.defineProperty(facade, name, {value: function(...args) {
      return spider[target].apply(spider, adapt(args));
    }, enumerable: true});
  }
  return facade;
};

// Android's pinned QuickJS wrapper drains native promise jobs after evaluate().
// Begin in one evaluation and read in the next; never poll or block the JS thread.
globalThis.__movieBeginCall = function(call) {
  const state = {done: false, failed: false};
  globalThis.__movieCallState = state;
  function reject(error) { state.error = error; state.failed = true; state.done = true; }
  function resolve(value) {
    try {
      state.value = typeof value === 'string' ? value : JSON.stringify(value);
      state.done = true;
    } catch (error) { reject(error); }
  }
  try {
    const value = call();
    if (value && typeof value.then === 'function') Promise.resolve(value).then(resolve, reject);
    else resolve(value);
  } catch (error) { reject(error); }
};
globalThis.__movieFinishCall = function() {
  const state = globalThis.__movieCallState;
  delete globalThis.__movieCallState;
  if (!state || !state.done)
    throw new Error('Spider Promise did not settle; external timers or event loops are unavailable');
  if (state.failed) throw state.error;
  return state.value;
};
