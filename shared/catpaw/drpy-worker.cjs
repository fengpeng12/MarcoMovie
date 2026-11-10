// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
'use strict';
const fs=require('node:fs');
const path=require('node:path');
const http=require('node:http');
const vm=require('node:vm');
const crypto=require('node:crypto');
const rsaPkcs1=require('./drpy-rsa.cjs');
const {parentPort,workerData}=require('node:worker_threads');
const {MAX_RESULT,validateManifest,validateCall}=require('./drpy-schema.cjs');
const manifest=validateManifest(workerData.manifest);
const stateFile=path.join(workerData.state,'local.json');
let storage=Object.create(null);
try { const value=JSON.parse(fs.readFileSync(stateFile,'utf8')); if(value&&typeof value==='object'&&!Array.isArray(value))storage=value; } catch(_){}
let sequence=0,deadline=0,initialized=false;
const pendingRequests=new Set();
const bridge=fn=>Object.setPrototypeOf((...args)=>{try{return JSON.stringify({value:fn(...args)});}catch(error){return JSON.stringify({error:/^drpy_/.test(error.message)?error.message:'drpy_host_error'});}},null);
const context=vm.createContext(Object.create(null),{name:'MarcoMovie DRPY',codeGeneration:{strings:true,wasm:false},microtaskMode:'afterEvaluate'});
context.__request=bridge((url,optionsText,sourceEncoding)=>{
  const options=JSON.parse(optionsText);
  const local = new URL(url, manifest.origin);
  if (local.protocol === 'pkg:') {
    if (String(options.method || 'GET').toUpperCase() !== 'GET' ||
        !Object.prototype.hasOwnProperty.call(manifest.modules, local.href)) {
      context.__drpyUnsupported='drpy_local_module_missing';
      throw Error('drpy_local_module_missing');
    }
    const text=manifest.modules[local.href];
    return {code:200,content:options.buffer===2?Buffer.from(text).toString('base64'):text,
      headers:{'content-type':local.pathname.endsWith('.json')?'application/json':'text/javascript'},url:local.href};
  }
  const duration=Math.min(Math.max(Number(options.timeout)||manifest.requestTimeoutMs,100),15000,deadline-Date.now());
  if(duration<=0)throw Error('drpy_http_timeout');
  const id=++sequence,buffer=new SharedArrayBuffer(MAX_RESULT+16),state=new Int32Array(buffer,0,4);
  pendingRequests.add(id);
  parentPort.postMessage({kind:'http',id,url:String(url),options,sourceEncoding,buffer,deadline:Math.min(deadline,Date.now()+duration)});
  const waited=Atomics.wait(state,0,0,duration);
  pendingRequests.delete(id);
  if(waited==='timed-out'&&Atomics.load(state,0)===0){parentPort.postMessage({kind:'cancel',id});throw Error('drpy_http_timeout');}
  const length=Atomics.load(state,1);
  if(length<0||length>MAX_RESULT)throw Error('drpy_http_response');
  const value=JSON.parse(Buffer.from(buffer,16,length).toString('utf8'));
  if(Atomics.load(state,0)!==1)throw Error(value.error||'drpy_http_response');
  return value;
});
context.__local=bridge((action,namespace,key,valueText)=>{
  if(typeof namespace!=='string'||namespace.length>256||typeof key!=='string'||key.length>512)throw Error('drpy_storage_key');
  const storageKey=JSON.stringify([namespace,key]);
  if(action==='get')return Object.prototype.hasOwnProperty.call(storage,storageKey)?storage[storageKey]:null;
  const updated={...storage};
  if(action==='delete')delete updated[storageKey];
  else if(action==='set')updated[storageKey]=JSON.parse(valueText);
  else throw Error('drpy_storage_action');
  const encoded=JSON.stringify(updated);
  if(Buffer.byteLength(encoded)>512*1024||Object.keys(updated).length>2048)throw Error('drpy_storage_limit');
  const temporary=stateFile+'.tmp';
  fs.writeFileSync(temporary,encoded,{mode:0o600});fs.renameSync(temporary,stateFile);storage=updated;
  return null;
});
context.__join=bridge((base,part)=>new URL(part,base||manifest.origin).href);
context.__random=bridge(length=>{if(!Number.isInteger(length)||length<0||length>65536)throw Error('drpy_random_size');return [...crypto.randomBytes(length)];});
context.__rsaPkcs1=bridge(rsaPkcs1);
const bootstrap=`
globalThis.window=globalThis; globalThis.self=globalThis; globalThis.navigator={appName:'Netscape'};
globalThis.console={log(){},warn(){},error(){}}; globalThis.print=globalThis.log=function(){};
function bridgeValue(text){const value=JSON.parse(text);if(value.error)throw new Error(value.error);return value.value;}
globalThis.crypto={getRandomValues(array){const bytes=bridgeValue(__random(array.byteLength));new Uint8Array(array.buffer,array.byteOffset,array.byteLength).set(bytes);return array;}};
globalThis.rsaPkcs1=(operation,key,input)=>{try{return bridgeValue(__rsaPkcs1(operation,key,input));}catch(e){unsupportedFeature('drpy_crypto_invalid');}};
globalThis.req=(url,options={})=>{
  // The pinned core's getHtml() drops rule_fetch_params.encoding. Carry the
  // normalized rule value separately: it is a fallback, not a call override.
  const encoding=typeof rule==='object'&&rule?(rule.encoding||rule.编码):'';
  return bridgeValue(__request(String(url),JSON.stringify(options),typeof encoding==='string'?encoding:''));
};
globalThis.__drpyOrigin=${JSON.stringify(manifest.origin)};
globalThis.joinUrl=(base,part)=>bridgeValue(__join(String(base||''),String(part||'')));
globalThis.local={get:(ns,key)=>bridgeValue(__local('get',String(ns),String(key),'')),set:(ns,key,value)=>bridgeValue(__local('set',String(ns),String(key),JSON.stringify(value))),delete:(ns,key)=>bridgeValue(__local('delete',String(ns),String(key),''))};
function unsupportedFeature(code){globalThis.__drpyUnsupported=code;throw new Error(code);}
// Upstream getProxyUrl() calls this host hook before considering its Android
// port-9978 fallback. Never return a non-existent Android proxy on other systems.
globalThis.getProxy=()=>globalThis.__drpyProxy;
`;
const selectors=`
function selectHtml(html,parts){
  const $=DRPYDeps.cheerio.load(String(html));let selected=$.root();
  for(const step of parts){
    if(!step)continue;
    const cuts=step.split('--'),selector=cuts.shift().trim();
    if(selector&&selector!=='*')selected=selected.find(selector);
    if(cuts.length){selected=selected.clone();for(const cut of cuts)selected.find(cut).remove();}
  }
  return {$,selected};
}
globalThis.pdfa=(html,expression)=>{const {$,selected}=selectHtml(html,String(expression).split('&&'));return selected.toArray().map(node=>$.html(node));};
globalThis.pdfl=pdfa;
globalThis.pdfh=(html,expression)=>{const parts=String(expression).split('&&');const field=parts.pop();const {selected}=selectHtml(html,parts);const first=selected.first();if(field==='Text')return first.text().trim();if(field==='Html')return first.html()||'';return first.attr(field)||'';};
globalThis.pd=(html,expression,base)=>{const value=pdfh(html,expression);return value?joinUrl(base,value):'';};
`;
function run(code,filename,timeout=5000){return new vm.Script(code,{filename}).runInContext(context,{timeout,microtaskMode:'afterEvaluate'});}
function cancelRequests(){for(const id of pendingRequests)parentPort.postMessage({kind:'cancel',id});pendingRequests.clear();}
function respond(res,status,value){res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(value));}
(async()=>{
  run(bootstrap,'drpy-host-bootstrap');
  run(fs.readFileSync(path.join(__dirname,'drpy-dependencies.js'),'utf8'),'drpy-dependencies');
  run(selectors,'drpy-host-selectors');
  run(fs.readFileSync(path.join(__dirname,'drpy-core.js'),'utf8'),'drpy-core');
  function execute(req,res,call,proxy=false){
    deadline=Date.now()+20000;
    parentPort.postMessage({kind:'call-start',deadline});
    try{
      context.__drpyUnsupported=null;
      if(!initialized){
        const initialization='__drpy.init((function(){\n'+manifest.rule+'\n;if(typeof rule!=="object"||rule===null)throw new Error("drpy_rule_missing");return rule;})());';
        run(initialization,'drpy-source-init',Math.max(1,deadline-Date.now()));
        if(context.__drpyUnsupported)throw Error(context.__drpyUnsupported);
        initialized=true;
      }
      // Parse data inside the VM. Embedding JSON as a JavaScript object literal
      // changes an own __proto__ property into a prototype assignment.
      const expression='(()=>{const args=JSON.parse('+JSON.stringify(JSON.stringify(call.args))+');const result=__drpy['+JSON.stringify(call.method)+'](...args);if(result&&typeof result.then==="function")throw new Error("drpy_async_result");return typeof result==="string"?result:JSON.stringify(result);})()';
      const raw=run(expression,'drpy-source-'+call.method,Math.max(1,deadline-Date.now()));
      if(context.__drpyUnsupported)throw Error(context.__drpyUnsupported);
      if(typeof raw!=='string'||Buffer.byteLength(raw)>MAX_RESULT)throw Error('drpy_result');
      const result=JSON.parse(raw);
      if(proxy){
        if(!Array.isArray(result)||result.length!==3||!Number.isInteger(result[0])||result[0]<200||result[0]>599||
            typeof result[1]!=='string'||result[1].length>256||/[\r\n\0]/.test(result[1]))throw Error('drpy_proxy_result');
        const payload=result[2];
        if(typeof payload!=='string'&&!(Array.isArray(payload)&&payload.every(v=>Number.isInteger(v)&&v>=0&&v<=255)))throw Error('drpy_proxy_result');
        let bytes=Buffer.from(payload),status=result[0];
        if(bytes.length>MAX_RESULT)throw Error('drpy_proxy_result');
        // Text may be rewritten by the outer router (notably relative HLS URLs).
        // Ignore Range there so byte offsets cannot describe a different body.
        const textResponse=/^text\/|json|mpegurl/i.test(result[1]);
        const headers={'Content-Type':result[1],'Cache-Control':'no-store','Accept-Ranges':textResponse?'none':'bytes'};
        if(req.headers.range&&status===200&&!textResponse){
          const range=/^bytes=(\d*)-(\d*)$/.exec(req.headers.range);
          let start=0,end=bytes.length-1;
          if(range&&range[1]){start=Number(range[1]);if(range[2])end=Math.min(end,Number(range[2]));}
          else if(range&&range[2])start=Math.max(0,bytes.length-Number(range[2]));
          if(!range||(!range[1]&&!range[2])||!Number.isSafeInteger(start)||!Number.isSafeInteger(end)||start>end||start>=bytes.length){
            res.writeHead(416,{'Content-Range':'bytes */'+bytes.length});return res.end();
          }
          headers['Content-Range']='bytes '+start+'-'+end+'/'+bytes.length;
          bytes=bytes.subarray(start,end+1);status=206;
        }
        headers['Content-Length']=bytes.length;
        res.writeHead(status,headers);res.end(req.method==='HEAD'?undefined:bytes);
      }else{
        if(!result||typeof result!=='object'||Array.isArray(result))throw Error('drpy_result');
        if(call.method==='category'&&Array.isArray(result.list)&&result.list.length===1){
          const row=result.list[0];
          if(row&&row.vod_id==='no_data'&&row.vod_name==='无数据,防无限请求'&&row.vod_remarks==='不要点,会崩的'&&row.vod_pic===''&&result.total===1&&result.pagecount===1&&result.limit===1){result.list=[];result.total=0;}
        }
        if(call.method==='play'&&raw.includes(context.__drpyProxy))parentPort.postMessage({kind:'playback'});
        respond(res,200,result);
      }
    }catch(error){
      const failure=context.__drpyUnsupported||error.message;
      const code=/^drpy_[a-z_]+$/.test(failure)?failure:error.code==='ERR_SCRIPT_EXECUTION_TIMEOUT'?'drpy_execution_timeout':'drpy_source_failed';
      respond(res,422,{error:code});
    }finally{cancelRequests();deadline=0;parentPort.postMessage({kind:'call-end'});}
  }
  const server=http.createServer((req,res)=>{
    if(req.url.length>8192)return respond(res,414,{error:'drpy_route'});
    const url=new URL(req.url,'http://127.0.0.1');
    if(url.pathname==='/proxy'&&['GET','HEAD'].includes(req.method)){
      return execute(req,res,{method:'proxy',args:[Object.fromEntries(url.searchParams)]},true);
    }
    if(req.method!=='POST'||req.url!=='/api/drpy')return respond(res,404,{error:'drpy_route'});
    let bytes=0,chunks=[];
    req.on('data',chunk=>{bytes+=chunk.length;if(bytes>MAX_RESULT){req.destroy();return;}chunks.push(chunk);});
    req.on('end',()=>{
      if(res.destroyed)return;
      let call;
      try{call=validateCall(JSON.parse(Buffer.concat(chunks).toString('utf8')));}catch(_){return respond(res,400,{error:'drpy_call'});}
      execute(req,res,call);
    });
  });
  server.requestTimeout=25000;server.headersTimeout=5000;
  server.listen(0,'127.0.0.1',()=>{
    context.__drpyProxy='http://127.0.0.1:'+server.address().port+'/proxy?do=js';
    parentPort.postMessage({kind:'ready',port:server.address().port});
  });
})().catch(()=>parentPort.postMessage({kind:'fatal',code:'drpy_start_failed'}));
