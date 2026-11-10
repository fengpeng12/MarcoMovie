// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
'use strict';
const http = require('node:http');
const https = require('node:https');
const zlib = require('node:zlib');
const {MAX_RESULT} = require('./drpy-schema.cjs');

// One instance per source worker. No shared cookie state or credential cache.
class SourceHttp {
  constructor(manifest) { this.manifest=manifest; this.pending=new Map(); this.closed=false; }
  cancel(id) {
    const entry=this.pending.get(id);
    if (!entry) return;
    this.pending.delete(id); clearTimeout(entry.timer);
    entry.request?.destroy(); entry.response?.destroy(); entry.stream?.destroy();
  }
  close() { this.closed=true; for(const id of [...this.pending.keys()]) this.cancel(id); }
  receive(message) {
    if (message.kind === 'cancel') return this.cancel(message.id);
    if (message.kind !== 'http' || this.closed) return;
    const {id,buffer}=message;
    if (!Number.isSafeInteger(id) || !(buffer instanceof SharedArrayBuffer) || buffer.byteLength !== MAX_RESULT+16 || this.pending.has(id)) return;
    const entry={request:null,response:null,stream:null,timer:null}; this.pending.set(id,entry);
    const finish=(value,error=false)=>{
      if(this.pending.get(id)!==entry)return;
      this.pending.delete(id);clearTimeout(entry.timer);
      let body=Buffer.from(JSON.stringify(value));
      if(body.length>MAX_RESULT){error=true;body=Buffer.from('{"error":"drpy_http_response_too_large"}');}
      Buffer.from(buffer,16,body.length).set(body);
      const state=new Int32Array(buffer,0,4);
      Atomics.store(state,1,body.length);Atomics.store(state,0,error?2:1);Atomics.notify(state,0);
    };
    const fail=code=>{finish({error:code},true);entry.request?.destroy();entry.response?.destroy();entry.stream?.destroy();};
    try {
      const options=message.options || {};
      const remaining=Number(message.deadline)-Date.now();
      const duration=Math.min(Math.max(Number(options.timeout)||this.manifest.requestTimeoutMs,100),15000,remaining);
      if(!Number.isFinite(duration)||duration<=0)throw Error('drpy_http_timeout');
      entry.timer=setTimeout(()=>fail('drpy_http_timeout'),duration);
      let url=new URL(message.url,this.manifest.origin);
      const inputHeaders=Object.create(null);
      if(url.origin===new URL(this.manifest.origin).origin)Object.assign(inputHeaders,this.manifest.headers);
      if(options.headers && typeof options.headers==='object' && !Array.isArray(options.headers))Object.assign(inputHeaders,options.headers);
      const headers=Object.create(null);
      for(const [key,value] of Object.entries(inputHeaders)) {
        if(!/^[!#$%&'*+.^_`|~0-9a-z-]+$/i.test(key)||typeof value!=='string'||/[\r\n\0]/.test(value)||value.length>8192)throw Error('drpy_http_headers');
        if(!/^(host|connection|content-length|transfer-encoding|accept-encoding)$/i.test(key))headers[key.toLowerCase()]=value;
      }
      headers['accept-encoding']='identity';
      if(url.username||url.password){
        if(!headers.authorization)headers.authorization='Basic '+Buffer.from(decodeURIComponent(url.username)+':'+decodeURIComponent(url.password)).toString('base64');
        url.username='';url.password='';
      }
      let method=String(options.method||'GET').toUpperCase();
      if(!['GET','POST','HEAD','PUT','PATCH','DELETE','OPTIONS'].includes(method))throw Error('drpy_http_method');
      let body=options.body ?? options.data;
      if(body!=null && typeof body!=='string')body=JSON.stringify(body);
      if(body && Buffer.byteLength(body)>MAX_RESULT)throw Error('drpy_http_body_too_large');
      const request=(target,redirects)=>{
        if(!['http:','https:'].includes(target.protocol))return fail('drpy_http_protocol');
        if(target.username||target.password)return fail('drpy_redirect_credentials');
        const client=(target.protocol==='https:'?https:http).request(target,{method,headers},response=>{
          entry.response=response;
          if([301,302,303,307,308].includes(response.statusCode)&&response.headers.location&&options.redirect!==0&&options.redirect!==false){
            response.resume();
            if(redirects>=5)return fail('drpy_http_redirect_limit');
            let next;
            try{next=new URL(response.headers.location,target);}catch(_){return fail('drpy_http_redirect');}
            if(next.origin!==target.origin){delete headers.authorization;delete headers.cookie;delete headers.cookie2;delete headers['proxy-authorization'];}
            if(response.statusCode===303&&method!=='HEAD'||[301,302].includes(response.statusCode)&&method==='POST'){
              method='GET';body=null;delete headers['content-type'];
            }
            return request(next,redirects+1);
          }
          let source=response;
          const encoding=String(response.headers['content-encoding']||'').toLowerCase();
          if(encoding==='gzip')source=response.pipe(zlib.createGunzip());
          else if(encoding==='deflate')source=response.pipe(zlib.createInflate());
          else if(encoding==='br')source=response.pipe(zlib.createBrotliDecompress());
          entry.stream=source;
          let size=0;const chunks=[];
          source.on('data',chunk=>{size+=chunk.length;if(size>MAX_RESULT)fail('drpy_http_response_too_large');else chunks.push(chunk);});
          source.on('error',()=>fail('drpy_http_response_failed'));
          response.on('error',()=>fail('drpy_http_response_failed'));
          source.on('end',()=>{
            try {
              const bytes=Buffer.concat(chunks);
              const responseHeaders=Object.fromEntries(Object.entries(response.headers).map(([k,v])=>[k,Array.isArray(v)?v.join('\n'):String(v??'')]));
              // Explicit call encoding can correct a bad response header. A
              // rule's inherited default only applies when neither declares it.
              const charset=String(options.encoding||/charset\s*=\s*["']?([^;\s"']+)/i.exec(String(response.headers['content-type']||''))?.[1]||message.sourceEncoding||'utf-8');
              const content=options.buffer===2?bytes.toString('base64'):new TextDecoder(charset).decode(bytes);
              finish({code:response.statusCode,content,headers:responseHeaders,url:target.href});
            }catch(_){fail('drpy_http_encoding');}
          });
        });
        entry.request=client;client.on('error',()=>fail('drpy_http_connection_failed'));
        if(body && !['GET','HEAD'].includes(method))client.write(body);
        client.end();
      };
      request(url,0);
    }catch(error){fail(/^drpy_/.test(error.message)?error.message:'drpy_http_request');}
  }
}
module.exports={SourceHttp};
