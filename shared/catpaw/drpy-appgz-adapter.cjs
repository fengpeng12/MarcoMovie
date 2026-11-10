// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
'use strict';
// Experimental original-Appgz protocol, independent of the CatPaw Guazi source.
// All origins, protocol keys and app headers come from a reviewed user import.
function serialize(v){if(typeof v==='function')return v.toString();if(Array.isArray(v))return '['+v.map(serialize).join(',')+']';if(v&&typeof v==='object')return '{'+Object.entries(v).map(([k,x])=>JSON.stringify(k)+':'+serialize(x)).join(',')+'}';return JSON.stringify(v);}
module.exports=function(config){
 if(!config||typeof config.origin!=='string')throw Error('endpoint configuration required');
 const origin=new URL(config.origin);
 if(!['http:','https:'].includes(origin.protocol)||origin.username||origin.password||origin.pathname!=='/'||origin.search||origin.hash)throw Error('endpoint configuration required');
 for(const key of ['privateKey','publicKey','signatureSuffix','utdidKey'])if(typeof config[key]!=='string'||!config[key]||config[key].length>2048)throw Error('protocol configuration required');
 const headerNames=['User-Agent','Version','PackageName','Ver','api-ver','code'];
 if(!config.headers||Object.keys(config.headers).length!==headerNames.length||headerNames.some(key=>typeof config.headers[key]!=='string'||!config.headers[key]||config.headers[key].length>256||/[\r\n\0]/.test(config.headers[key])))throw Error('protocol headers required');
 const cfg={...config,origin:origin.origin};
 const regions=['中国大陆','中国香港','中国台湾','美国','日本','韩国','泰国','印度','其他'];
 const years=Array.from({length:17},(_,i)=>String(2026-i)).concat(['2009~2000','90年代','80年代']);
 const values=items=>[{n:'全部',v:''},...items.map(v=>({n:v,v}))];
 const filters={};
 for(const category of ['1','2','3','4'])filters[category]=[
  {name:'地区',key:'area',value:values(category==='4'?['中国大陆','美国','日本','其他']:regions)},
  {name:'年份',key:'year',value:values(category==='3'?years.slice(0,7).concat(['更早']):category==='4'?years.concat(['更早']):years)}];
 const rule={
  title:'Appgz',host:cfg.origin,homeUrl:'/',url:'/category/fyclass/fypage',detailUrl:'/detail/fyid',searchUrl:'/search?wd=**',
  class_name:'电影&电视剧&动漫&综艺',class_url:'1&2&4&3',filter:filters,filterable:1,searchable:2,quickSearch:1,limit:30,timeout:15000,
  headers:cfg.headers,预处理:'js:rule._init();',推荐:'js:VODS=rule._home();',
  一级:'js:VODS=rule._category(MY_CATE,MY_PAGE,MY_FL);',搜索:'js:VODS=rule._search(KEY,MY_PAGE);',
  二级:'js:VOD=rule._detail(orId);',play_parse:true,lazy:'js:input=rule._play(input);',
  _random:function(){var a=new Uint8Array(8);crypto.getRandomValues(a);return Array.prototype.map.call(a,function(v){return ('0'+v.toString(16)).slice(-2);}).join('').toUpperCase();},
  _hash:function(text){var n=0;for(var i=0;i<text.length;i++)n=(Math.imul(n,31)+text.charCodeAt(i))|0;return n;},
  _init:function(){
   this._key=this._random();this._iv=this._random();
   var saved=local.get('appgz-v1','device');
   if(saved&&typeof saved==='object'&&/^[A-F0-9]{40}$/.test(saved.new_key)&&/^[A-Za-z0-9+/]{24}$/.test(saved.old_key)&&typeof saved.token==='string'&&saved.token.length<=4096){this._state=saved;return;}
   var id=this._random(),random=parseInt(this._random().slice(0,8),16),hash=this._hash(id);
   var data=CryptoJS.lib.WordArray.create([Math.floor(Date.now()/1000),random,0x03000000|((hash>>>16)&65535),(hash&65535)<<16],14);
   var check=this._hash(CryptoJS.HmacSHA1(data,cfg.utdidKey).toString(CryptoJS.enc.Base64));
   data.concat(CryptoJS.lib.WordArray.create([check],4));
   this._state={new_key:CryptoJS.SHA1(id+this._random()).toString().toUpperCase(),old_key:data.toString(CryptoJS.enc.Base64),token:'',registrationAttempted:false};
   this._save();
  },
  _save:function(){local.set('appgz-v1','device',this._state);},
  _decode:function(envelope){
   if(!envelope||Number(envelope.code)!==200)unsupportedFeature('drpy_source_unavailable');
   var data=envelope.data,keys;
   try{
    if(!data||typeof data.keys!=='string'||typeof data.response_key!=='string')throw Error();
    keys=JSON.parse(CryptoJS.enc.Base64.parse(rsaPkcs1('decrypt',cfg.privateKey,data.keys)).toString(CryptoJS.enc.Utf8));
    if(!keys||typeof keys.key!=='string'||typeof keys.iv!=='string'||!/^[\x20-\x7e]{16}$/.test(keys.key)||!/^[\x20-\x7e]{16}$/.test(keys.iv))throw Error();
    var hex=data.response_key.replace(/\\/g,'');if(!hex||hex.length>2*1024*1024||hex.length%32||!/^[a-f0-9]+$/i.test(hex))throw Error();
    var plain=CryptoJS.AES.decrypt({ciphertext:CryptoJS.enc.Hex.parse(hex)},CryptoJS.enc.Utf8.parse(keys.key),{iv:CryptoJS.enc.Utf8.parse(keys.iv),mode:CryptoJS.mode.CBC,padding:CryptoJS.pad.NoPadding});
    var byte=function(i){return (plain.words[i>>>2]>>>(24-(i%4)*8))&255;},padding=byte(plain.sigBytes-1);
    if(padding<1||padding>16||plain.sigBytes<padding)throw Error();
    for(var i=plain.sigBytes-padding;i<plain.sigBytes;i++)if(byte(i)!==padding)throw Error();
    plain.sigBytes-=padding;plain.clamp();var result=JSON.parse(plain.toString(CryptoJS.enc.Utf8));
    if(!result||typeof result!=='object'||Array.isArray(result))throw Error();return result;
   }catch(e){unsupportedFeature('drpy_source_response');}
  },
  _api:function(path,payload,token){
   var allowed=['/App/Authentication/Device/signUp','/App/Authentication/Device/signIn','/App/IndexList/index','/App/IndexList/indexList','/App/Index/findMoreVod','/App/IndexPlay/playInfo','/App/Resource/Vurl/show','/App/Resource/VurlDetail/showOne'];
   if(allowed.indexOf(path)<0)unsupportedFeature('drpy_source_response');
   token=token===undefined?this._state.token:token;
   var stamp=String(Math.floor(Date.now()/1000)),keys=rsaPkcs1('encrypt',cfg.publicKey,CryptoJS.enc.Utf8.parse(JSON.stringify({iv:this._iv,key:this._key})).toString(CryptoJS.enc.Base64));
   var encrypted=CryptoJS.AES.encrypt(JSON.stringify(payload),CryptoJS.enc.Utf8.parse(this._key),{iv:CryptoJS.enc.Utf8.parse(this._iv),mode:CryptoJS.mode.CBC,padding:CryptoJS.pad.Pkcs7}).ciphertext.toString().toUpperCase();
   var text='token_id=,token='+token+',phone_type=1,request_key='+encrypted+',app_id=1,time='+stamp+',keys='+keys+cfg.signatureSuffix;
   var fields={token:token,token_id:'',phone_type:'1',time:stamp,phone_model:'oneplus-hd1900',keys:keys,request_key:encrypted,signature:CryptoJS.MD5(text).toString().toUpperCase(),app_id:'1',ad_version:'1'};
   var body=Object.keys(fields).map(function(k){return encodeURIComponent(k)+'='+encodeURIComponent(fields[k]);}).join('&');
   var headers=Object.assign({},cfg.headers,{'Content-Type':'application/x-www-form-urlencoded',Referer:cfg.origin});
   var response;try{response=req(cfg.origin+path,{method:'POST',body:body,headers:headers,redirect:0,timeout:15000});}
   catch(e){unsupportedFeature(/^drpy_[a-z_]+$/.test(e.message)?e.message:'drpy_source_unavailable');}
   if(response.code!==200)unsupportedFeature('drpy_source_unavailable');
   var doc;try{doc=JSON.parse(response.content);}catch(e){unsupportedFeature('drpy_source_response');}return this._decode(doc);
  },
  _login:function(){
   if(this._state.token)return;
   var payload={old_key:this._state.old_key,new_key:this._state.new_key},signUp=!this._state.registrationAttempted;
   // Commit the attempt before network I/O. A timeout/retry never registers a
   // second identity. The next call signs in with exactly the same device keys.
   if(signUp){this._state.registrationAttempted=true;this._save();payload.phone_type=1;payload.code='';}
   var doc=this._api('/App/Authentication/Device/'+(signUp?'signUp':'signIn'),payload,'');
   if(typeof doc.token!=='string'||!doc.token||doc.token.length>4096)unsupportedFeature('drpy_authentication_required');
   this._state.token=doc.token;this._save();
  },
  _rows:function(doc){if(!doc||!Array.isArray(doc.list))unsupportedFeature('drpy_source_response');return doc.list;},
  _id:function(value){value=String(value);if(!/^\d{1,20}$/.test(value))unsupportedFeature('drpy_source_response');return value;},
  _card:function(row,home){
   var name=home?row.c_name:row.vod_name;if(typeof name!=='string'||!name)return null;
   return {vod_id:this._id(row.vod_id),vod_name:name,vod_pic:String((home?row.c_pic:row.vod_pic)||''),vod_remarks:String((home?row.new_continue:row.vod_scroe)||''),vod_actor:String(row.vod_actor||''),vod_director:String(row.vod_director||'')};
  },
  _home:function(){
   var groups=this._rows(this._api('/App/IndexList/index',{pid:'1'})),self=this,result=[];
   groups.forEach(function(group){if(typeof group.type==='string'&&group.type.indexOf('热门推荐')!==-1)self._rows(group).forEach(function(row){var card=self._card(row,true);if(card)result.push(card);});});return result;
  },
  _category:function(category,page,filters){
   category=String(category);var sub={'1':'5','2':'12','3':'22','4':'30'}[category];
   if(!sub||!/^\d+$/.test(String(page))||Number(page)<1)unsupportedFeature('drpy_filter_not_supported');
   var selected={area:'0',year:'0'},definitions=this.filter[category];
   Object.keys(filters||{}).forEach(function(key){var value=String(filters[key]||'').trim();if(!value||value==='全部')return;
    var field=definitions.filter(function(v){return v.key===key;})[0];if(!field)unsupportedFeature('drpy_filter_not_supported');
    var option=field.value.filter(function(v){return v.v===value||v.n===value;})[0];if(!option)unsupportedFeature('drpy_filter_not_supported');selected[key]=option.v||'0';});
   this._login();var self=this;
   return this._rows(this._api('/App/IndexList/indexList',{area:selected.area,sub:sub,year:selected.year,pageSize:'30',sort:'d_id',page:String(page),tid:category})).map(function(row){return self._card(row,false);}).filter(Boolean);
  },
  _search:function(word,page){
   if(Number(page)>1)return [];if(typeof word!=='string'||!word||word.length>256)unsupportedFeature('drpy_source_response');
   this._login();var self=this;
   return this._rows(this._api('/App/Index/findMoreVod',{keywords:word,order_val:'1'})).filter(function(row){return typeof row.vod_name==='string'&&row.vod_name.indexOf(word)!==-1;}).map(function(row){return self._card(row,false);}).filter(Boolean);
  },
  _params:function(value){
   if(typeof value!=='string'||value.length>4096)unsupportedFeature('drpy_media_unresolved');
   var parts=value.split('?').pop().split('&'),params={};
   parts.forEach(function(part){var n=part.indexOf('=');if(n<0)return;var key=part.slice(0,n),value;try{value=decodeURIComponent(part.slice(n+1));}catch(e){unsupportedFeature('drpy_media_unresolved');}
    if(['vod_d_id','vurl_id','domain_type','resolution','type'].indexOf(key)<0)return;if(Object.prototype.hasOwnProperty.call(params,key)||!value||value.length>128||/[\x00-\x1f#$&]/.test(value))unsupportedFeature('drpy_media_unresolved');params[key]=value;});
   if(Object.keys(params).length!==5)unsupportedFeature('drpy_media_unresolved');
   return {domain_type:params.domain_type,vod_id:this._id(params.vod_d_id),type:params.type,resolution:params.resolution,vurl_id:params.vurl_id};
  },
  _detail:function(id){
   id=this._id(id);this._login();
   var info=this._api('/App/IndexPlay/playInfo',{token_id:'',vod_id:id,mobile_time:String(Math.floor(Date.now()/1000)),token:this._state.token}).vodInfo;
   if(!info||typeof info!=='object'||!info.vod_name)unsupportedFeature('drpy_source_response');
   var self=this,episodes=this._rows(this._api('/App/Resource/Vurl/show',{vurl_cloud_id:'2',vod_d_id:id})).map(function(row){
    var play=row.play||{},param='';['1080','720','480'].some(function(q){if(play[q]&&typeof play[q].param==='string'&&play[q].param){param=play[q].param;return true;}return false;});
    if(!param)return '';var title=String(row.title||'').replace(/[#$]/g,' ');return title+'$'+base64Encode(JSON.stringify(self._params(param)));
   }).filter(Boolean);
   if(!episodes.length)unsupportedFeature('drpy_media_unresolved');
   return {vod_id:id,vod_name:String(info.vod_name),vod_pic:String(info.vod_pic||''),vod_year:String(info.vod_year||''),vod_area:String(info.vod_area||''),vod_remarks:String(info.vod_title||''),vod_actor:String(info.vod_actor||''),vod_director:String(info.vod_director||''),vod_content:'内详',vod_play_from:'专线播放',vod_play_url:episodes.join('#')};
  },
  _play:function(value){
   var payload;try{payload=JSON.parse(value);}catch(e){unsupportedFeature('drpy_media_unresolved');}
   if(!payload||typeof payload!=='object'||Object.keys(payload).sort().join(',')!=='domain_type,resolution,type,vod_id,vurl_id')unsupportedFeature('drpy_media_unresolved');
   Object.keys(payload).forEach(function(k){if(typeof payload[k]!=='string'||!payload[k]||payload[k].length>128||/[\x00-\x1f]/.test(payload[k]))unsupportedFeature('drpy_media_unresolved');});this._id(payload.vod_id);
   this._login();var url=this._api('/App/Resource/VurlDetail/showOne',payload).url;
   if(typeof url!=='string'||url.length>8192||/[\x00-\x20\x7f\\]/.test(url)||!/^https?:\/\/[^/?#@]+(?:[/?#]|$)/i.test(url))unsupportedFeature('drpy_media_protocol');
   try{url=joinUrl(cfg.origin,url);}catch(e){unsupportedFeature('drpy_media_protocol');}
   // Original KJ marks this returned anti-leech playlist as a failed account.
   // Report it; never rotate identities or auto-register again to evade it.
   if(/^https?:\/\/[^/?#]+([^?#]*)/i.exec(url)[1].replace(/\/+$/,'').toLowerCase().endsWith('/hls/index.m3u8'))unsupportedFeature('drpy_authentication_required');
   return {parse:0,url:url,header:{'User-Agent':'Lavf/57.83.100'}};
  }
 };
 return 'var cfg='+JSON.stringify(cfg)+';\nvar rule='+serialize(rule)+';';
};
