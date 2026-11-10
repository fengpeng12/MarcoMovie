// Owned synthetic transport. No sockets, fetch, Dart HTTP or external services.
(function () {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  function base64(text) {
    const encoded = encodeURIComponent(text), bytes = [];
    for (let i = 0; i < encoded.length; i++) {
      if (encoded[i] === '%') { bytes.push(parseInt(encoded.slice(i + 1, i + 3), 16)); i += 2; }
      else bytes.push(encoded.charCodeAt(i));
    }
    let result = '';
    for (let i = 0; i < bytes.length; i += 3) {
      const count = Math.min(3, bytes.length - i);
      const value = bytes[i] << 16 | (bytes[i + 1] || 0) << 8 | (bytes[i + 2] || 0);
      result += alphabet[value >>> 18] + alphabet[value >>> 12 & 63] +
        (count > 1 ? alphabet[value >>> 6 & 63] : '=') + (count > 2 ? alphabet[value & 63] : '=');
    }
    return result;
  }
  const records = [];
  const proxyRecords = [];
  const bridge = {
    siteKey: 'owned-ios-catvod-source',
    request(url, options) {
      if (this !== bridge) throw Error('Synthetic bridge request receiver was lost');
      if (!url.startsWith('https://fixture.invalid/catvod/')) throw Error('Synthetic fixture URL required');
      records.push({url, options: JSON.parse(JSON.stringify(options))});
      if (url.endsWith('/transport')) throw Error('owned transport failure');
      if (url.endsWith('/async-transport')) return Promise.reject(Error('owned async transport failure'));
      const response = {code: 200, url, headers: {'Content-Type': 'application/json; charset=utf-8'},
        content: base64(JSON.stringify({url, ...options}))};
      if (url.endsWith('/bytes')) {
        response.code = 206; response.headers = {'content-type': 'application/octet-stream', 'x-owned': 'bytes'};
        response.content = 'AP+AQQ==';
      } else if (url.endsWith('/text')) response.content = '5Lit5paH';
      else if (url.endsWith('/failed')) { response.code = 503; response.content = 'dW5hdmFpbGFibGU='; }
      else if (url.endsWith('/bad-json')) response.content = 'bm90LWpzb24=';
      else if (url.endsWith('/bad-base64')) response.content = 'non canonical';
      else if (url.endsWith('/unsupported-charset')) response.headers = {'content-type': 'text/plain; charset=gbk'};
      // Exercise both synchronous and Promise-based bridge implementations.
      return url.includes('/echo') ? Promise.resolve(response) : response;
    },
    proxyUrl(params) {
      if (this !== bridge) throw Error('Synthetic bridge proxy receiver was lost');
      proxyRecords.push({...params});
      return 'http://127.0.0.1:18191/_spider/owned/proxy?do=js&siteKey=owned-ios-catvod-source' +
        Object.entries(params).map(([key, value]) => '&' + encodeURIComponent(key) + '=' + encodeURIComponent(value)).join('');
    }
  };
  globalThis.__movieCatvodBridge = bridge;
  globalThis.__catvodNativeRecords = records;
  globalThis.__catvodNativeProxyRecords = proxyRecords;
})();
