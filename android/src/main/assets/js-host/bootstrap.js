globalThis.global=globalThis;
globalThis.window=globalThis;
globalThis.self=globalThis;
globalThis.req=function(url, options){return JSON.parse(__hostRequest(String(url),JSON.stringify(options||{})));};
globalThis.local={
  get:function(space,key){return __hostStorage('get',String(space),String(key),'');},
  set:function(space,key,value){return __hostStorage('set',String(space),String(key),String(value));},
  delete:function(space,key){return __hostStorage('delete',String(space),String(key),'');}
};
globalThis.pdfh=function(html,selector){return __hostHtml(String(html||''),String(selector||''),'one');};
globalThis.pdfa=function(html,selector){return JSON.parse(__hostHtml(String(html||''),String(selector||''),'many'));};
globalThis.pd=function(html,selector,base){return joinUrl(base||'',pdfh(html,selector));};
globalThis.pdfl=globalThis.pdfa;
globalThis.joinUrl=function(base,part){return __hostJoin(String(base||''),String(part||''));};
globalThis.getProxy=function(){return __proxyAddress;};
globalThis.log=function(){};
globalThis.print=globalThis.log;
globalThis.console={log:log,info:log,warn:log,error:log,debug:log};
globalThis.atob=function(s){return __hostBase64(String(s),false);};
globalThis.btoa=function(s){return __hostBase64(String(s),true);};
globalThis.encodeStr=function(s,encoding){return __hostEncode(String(s),String(encoding||'UTF-8'));};
globalThis.decodeStr=function(s,encoding){return __hostDecode(String(s),String(encoding||'UTF-8'));};
globalThis.sleep=function(ms){return __hostSleep(Number(ms));};
// Timers cannot retain work past a request; async modules should use synchronous req.
globalThis.setTimeout=function(){throw new Error('Asynchronous timer is not supported by this source host');};
