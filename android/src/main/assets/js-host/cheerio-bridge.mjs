import {JSONPath} from 'assets://js-host/jsonpath.mjs';
// DRPY's host dependency uses JSONPath and Jinja; HTML selectors are native pdfh/pdfa.
export default {
  jp(path, json) { return JSONPath({path, json, wrap:true}); },
  jinja2(template, values) {
    if (typeof globalThis.jinja !== 'undefined') return globalThis.jinja.render(template, values);
    throw new Error('Jinja dependency has not initialized');
  }
};
