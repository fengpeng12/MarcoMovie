// Synthetic loopback fixture. Never connects to a real source.
'use strict';
const http=require('node:http'),crypto=require('node:crypto');
const pair=(modulusLength=1024)=>crypto.generateKeyPairSync('rsa',{modulusLength});
const requestKeys=pair(),responseKeys=pair(1023);
const der=(key,type)=>key.export({format:'der',type}).toString('base64');
const config={origin:'',publicKey:der(requestKeys.publicKey,'spki'),privateKey:der(responseKeys.privateKey,'pkcs8'),
 signatureSuffix:'fixture-signing-suffix',utdidKey:'fixture-utdid-hmac',headers:{'User-Agent':'Fixture-Agent','Version':'1','PackageName':'example.fixture','Ver':'1.0','api-ver':'1.0',code:'FIXTURE'}};
let mode='normal';const records=[];
function decrypt(cipher){
 const block=crypto.privateDecrypt({key:requestKeys.privateKey,padding:crypto.constants.RSA_NO_PADDING},Buffer.from(cipher,'base64'));
 const end=block.indexOf(0,2);if(block[0]!==0||block[1]!==2||end<10)throw Error('fixture padding');return block.subarray(end+1);
}
function aes(data,key,iv,encrypt){
 const fn=encrypt?crypto.createCipheriv:crypto.createDecipheriv;
 const engine=fn('aes-128-cbc',Buffer.from(key),Buffer.from(iv));return Buffer.concat([engine.update(data),engine.final()]);
}
function response(value,code=200){
 const key=crypto.randomBytes(8).toString('hex'),iv=crypto.randomBytes(8).toString('hex');
 return {code,msg:code===200?'fixture success':'fixture upstream failure',data:{
  keys:crypto.publicEncrypt({key:responseKeys.publicKey,padding:crypto.constants.RSA_PKCS1_PADDING},Buffer.from(JSON.stringify({key,iv}))).toString('base64'),
  response_key:aes(Buffer.from(JSON.stringify(value)),key,iv,true).toString('hex').toUpperCase()}};
}
const server=http.createServer((req,res)=>{
 const url=new URL(req.url,'http://localhost');
 const send=(status,value)=>{const body=Buffer.from(JSON.stringify(value));res.writeHead(status,{'content-type':'application/json','content-length':body.length});res.end(body);};
 if(url.pathname==='/control'){mode=url.searchParams.get('mode')||'normal';return send(200,{records,mode});}
 if(url.pathname==='/media.m3u8'){res.writeHead(200,{'content-type':'application/vnd.apple.mpegurl'});return res.end('#EXTM3U\n#EXT-X-ENDLIST\n');}
 if(req.method!=='POST')return send(404,{});
 let body='';req.on('data',chunk=>{body+=chunk;if(body.length>65536)req.destroy();});
 req.on('end',()=>{
  try{
   const form=Object.fromEntries(new URLSearchParams(body));
   if(Object.keys(form).sort().join(',')!=='ad_version,app_id,keys,phone_model,phone_type,request_key,signature,time,token,token_id')throw Error('fixture form');
   if(form.phone_type!=='1'||form.app_id!=='1'||form.ad_version!=='1'||form.token_id!==''||form.phone_model!=='oneplus-hd1900'||!/^[A-F0-9]+$/.test(form.request_key))throw Error('fixture fields');
   const signed='token_id=,token='+form.token+',phone_type=1,request_key='+form.request_key+',app_id=1,time='+form.time+',keys='+form.keys+config.signatureSuffix;
   if(crypto.createHash('md5').update(signed).digest('hex').toUpperCase()!==form.signature)throw Error('fixture signature');
   for(const [k,v] of Object.entries(config.headers))if(req.headers[k.toLowerCase()]!==v)throw Error('fixture headers');
   if(req.headers.referer!==config.origin||!req.headers['content-type'].startsWith('application/x-www-form-urlencoded'))throw Error('fixture content type');
   const keys=JSON.parse(decrypt(form.keys));
   const payload=JSON.parse(aes(Buffer.from(form.request_key,'hex'),keys.key,keys.iv,false));
   records.push({path:url.pathname,payload,token:form.token});
   let value;
   const card={vod_id:'42',vod_name:'中文 Fixture',vod_pic:config.origin+'/poster.png',vod_scroe:'8.0'};
   if(mode==='upstream')return send(200,response({},0));
   if(mode==='redirect'){res.writeHead(307,{location:config.origin.replace('127.0.0.1','localhost')+'/redirect-target'});return res.end();}
   if(url.pathname==='/App/Authentication/Device/signUp'||url.pathname==='/App/Authentication/Device/signIn'){
    if(!/^[A-F0-9]{40}$/.test(payload.new_key)||!/^[A-Za-z0-9+/]{24}$/.test(payload.old_key))throw Error('fixture identity');
    const id=Buffer.from(payload.old_key,'base64');if(id.length!==18||id[8]!==3||id[9]!==0)throw Error('fixture utdid');
    const signature=crypto.createHmac('sha1',config.utdidKey).update(id.subarray(0,14)).digest('base64');
    let hash=0;for(const c of signature)hash=(Math.imul(hash,31)+c.charCodeAt(0))|0;
    if(id.readInt32BE(14)!==hash)throw Error('fixture utdid checksum');
    const signup=url.pathname.endsWith('signUp');
    if(Object.keys(payload).sort().join(',')!==(signup?'code,new_key,old_key,phone_type':'new_key,old_key')||form.token!=='')throw Error('fixture login');
    if(signup&&(payload.phone_type!==1||payload.code!==''))throw Error('fixture registration');
    value={token:'fixture-device-token'};
   }else if(url.pathname==='/App/IndexList/index'){
    if(JSON.stringify(payload)!=='{"pid":"1"}')throw Error('fixture home');
    value={list:[{type:'热门推荐',list:[{vod_id:'42',c_name:'中文 Fixture',c_pic:card.vod_pic,new_continue:'HD'}]},{type:'other',list:[card]}]};
   }else{
    if(form.token!=='fixture-device-token')throw Error('fixture token');
    if(url.pathname==='/App/IndexList/indexList'){
     if(Object.keys(payload).sort().join(',')!=='area,page,pageSize,sort,sub,tid,year'||payload.pageSize!=='30'||payload.sort!=='d_id'||({'1':'5','2':'12','3':'22','4':'30'})[payload.tid]!==payload.sub)throw Error('fixture category');
     value={list:mode==='empty'?[]:[card]};
    }else if(url.pathname==='/App/Index/findMoreVod'){
     if(Object.keys(payload).sort().join(',')!=='keywords,order_val'||payload.order_val!=='1')throw Error('fixture search');
     value={list:mode==='empty'?[]:[{...card,vod_name:payload.keywords+' Fixture'},{...card,vod_id:'43',vod_name:'Unrelated'}]};
    }else if(url.pathname==='/App/IndexPlay/playInfo'){
     if(Object.keys(payload).sort().join(',')!=='mobile_time,token,token_id,vod_id'||payload.token!==form.token||payload.token_id!==''||payload.vod_id!=='42')throw Error('fixture detail');
     value={vodInfo:{...card,vod_year:'2026',vod_area:'中国大陆',vod_title:'HD',vod_actor:'Fixture Actor',vod_director:'Fixture Director'}};
    }else if(url.pathname==='/App/Resource/Vurl/show'){
     if(JSON.stringify(payload)!=='{"vurl_cloud_id":"2","vod_d_id":"42"}')throw Error('fixture episode');
     value={list:[{title:'Episode 1',play:{'1080':{param:''},'720':{param:'vod_d_id=42&vurl_id=7&domain_type=1&resolution=720&type=1'},'480':{param:'vod_d_id=42&vurl_id=8&domain_type=1&resolution=480&type=1'}}}]};
    }else if(url.pathname==='/App/Resource/VurlDetail/showOne'){
     if(Object.keys(payload).sort().join(',')!=='domain_type,resolution,type,vod_id,vurl_id'||payload.vod_id!=='42'||payload.vurl_id!=='7'||payload.resolution!=='720')throw Error('fixture play');
     value={url:mode==='scheme'?'file:///fixture.m3u8':mode==='userinfo'?config.origin.replace('://','://private:secret@')+'/media.m3u8':mode==='antileech'?config.origin+'/HLS/index.m3u8/?t=fixture':config.origin+'/media.m3u8'};
    }else throw Error('fixture unknown path');
   }
   let envelope=response(value);
   if(mode==='rsa')envelope.data.keys='invalid';
   if(mode==='aes')envelope.data.response_key='00'.repeat(16);
   send(200,envelope);
  }catch(error){send(400,{error:error.message});}
 });
});
server.listen(0,'127.0.0.1',()=>{config.origin='http://127.0.0.1:'+server.address().port;process.stdout.write(JSON.stringify(config)+'\n');});
