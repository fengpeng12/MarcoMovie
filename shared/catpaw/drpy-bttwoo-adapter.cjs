// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
'use strict';
// App-owned protocol adapter. Configuration is data from a reviewed user import.
function serialize(v){if(typeof v==='function')return v.toString();if(Array.isArray(v))return '['+v.map(serialize).join(',')+']';if(v&&typeof v==='object')return '{'+Object.entries(v).map(([k,x])=>JSON.stringify(k)+':'+serialize(x)).join(',')+'}';return JSON.stringify(v);}
module.exports=function(config){
 if(!config||typeof config.origin!=='string'||!/^https?:\/\//.test(config.origin)||typeof config.userAgent!=='string'||/[\r\n]/.test(config.userAgent)||typeof config.playKey!=='string'||!config.playKey||config.playKey.length>256)throw Error('endpoint configuration required');
 const rule={
  title:'Bttwoo',host:config.origin,homeUrl:'/',url:'/filter?classify=fyclass&page=fypage',searchUrl:'/search?q=**',
  class_name:'电影&电视剧&动漫',class_url:'1&2&3',searchable:2,quickSearch:1,filterable:0,limit:24,timeout:8000,
  headers:{'User-Agent':config.userAgent},
  预处理:'js:rule._init();',推荐:'js:VODS=rule._list(rule._home,\'div[class*="4xl:grid-cols-8"] div[data-vod-id]\',\'home\');',
  一级:'js:VODS=rule._category(input,MY_FL);',
  搜索:'js:VODS=rule._list(rule._get(rule._catalog(input)),\'div.group.relative\',\'search\');',
  二级:'js:VOD=rule._detail(input);',play_parse:true,lazy:'js:input=rule._play(input);',
  _address:function(value){
   if(typeof value!=='string'||!value||/[\x00-\x1f\x7f\\]/.test(value))unsupportedFeature('drpy_media_protocol');
   var url=joinUrl(cfg.origin,value),match=/^(https?):\/\/([^/?#]+)([^?#]*)(?:[?#]|$)/i.exec(url);
   if(!match||match[2].indexOf('@')!==-1)unsupportedFeature('drpy_media_protocol');
   return {url:url,origin:match[1].toLowerCase()+'://'+match[2].toLowerCase(),path:match[3]||'/'};
  },
  _catalog:function(value){var x=this._address(value);if(x.origin!==this._address(cfg.origin).origin)unsupportedFeature('drpy_source_origin');return x.url;},
  _check:function(html){if(/(?:verify you are human|checking your browser|人机验证)/i.test(pdfh(html,'body&&Text')))unsupportedFeature('drpy_verification_required');return html;},
  _get:function(url,referer){
   var response;try{response=req(this._catalog(url),{timeout:8000,headers:{'User-Agent':cfg.userAgent,Referer:referer||cfg.origin}});}catch(e){unsupportedFeature(/^drpy_[a-z_]+$/.test(e.message)?e.message:'drpy_source_unavailable');}
   var body=this._check(response.content||'');if(response.code<200||response.code>=300)unsupportedFeature('drpy_source_unavailable');return body;
  },
  _init:function(){this._home=this._get(cfg.origin);if(!pdfa(this._home,'div[data-vod-id]').length)unsupportedFeature('drpy_source_unavailable');},
  _category:function(url,filters){
   Object.keys(filters||{}).forEach(function(key){var value=filters[key];if(value!==undefined&&value!==null&&String(value).trim()!==''&&String(value).trim()!=='全部')unsupportedFeature('drpy_filter_not_supported');});
   return this._list(this._get(url),'div[data-vod-id]','cate');
  },
  _list:function(html,selector,kind){
   this._check(html);var self=this,seen={};
   return pdfa(html,selector).map(function(item){
    if(pdfa(item,'span:contains(VIP)').length)return null;
    var href=pdfh(item,'a[href*="play"]&&href'),name=pdfh(item,'img.object-cover&&alt');
    if(!href||!name)return null;var url=self._catalog(href);if(seen[url])return null;seen[url]=true;
    return {vod_id:url,vod_name:name,vod_pic:pd(item,'img.object-cover&&data-src',cfg.origin),
      vod_remarks:kind==='home'?pdfh(item,'span.text-right&&Text'):kind==='cate'?pdfh(item,'span.text-text-muted&&Text'):''};
   }).filter(Boolean);
  },
  _detail:function(url){
   var html=this._get(url,this._catalog(url));
   var nav=pdfh(html,'nav#navbar&&x-data'),match=/userlink:'([^']*)',/.exec(nav),userlink=match?match[1]:'';
   var self=this,episodes=pdfa(html,'div[style] a[href*="play"]').map(function(a){
    var href=pdfh(a,'a&&href'),id=/handleEpisodeClick\(.*?,\s*'(\d+)'.*?\)/.exec(pdfh(a,'a&&@click.prevent'));
    if(!href||!id)return '';var address=self._address(self._catalog(href));
    if(!/^\/play\/[^/]+$/.test(address.path))return '';
    return pdfh(a,'span[x-show]&&Text')+'$'+base64Encode(JSON.stringify({video:address.path.slice(6),play_id:id[1],userlink:userlink}));
   }).filter(Boolean);
   if(!episodes.length)unsupportedFeature('drpy_source_unavailable');
   var result={vod_id:url,vod_name:pdfh(html,'h1&&Text'),vod_pic:pd(html,'img.object-cover&&src',cfg.origin),vod_content:pdfh(html,'p[class="text-xs text-text-secondary leading-relaxed"]&&Text'),vod_play_from:'自动',vod_play_url:episodes.join('#')};
   pdfa(html,'div[class="grid grid-cols-3 gap-2 text-xs"] div').forEach(function(item){var text=pdfh(item,'div&&Text');var m=/^(导演|主演|编剧)\s*[:：]?\s*(.*)/.exec(text);if(m)result[m[1]==='导演'?'vod_director':m[1]==='主演'?'vod_actor':'vod_writer']=m[2];});
   return result;
  },
  _play:function(value){
   var p;try{p=JSON.parse(value);}catch(e){unsupportedFeature('drpy_media_unresolved');}
   if(!p||typeof p.video!=='string'||!p.video||p.video.length>256||typeof p.play_id!=='string'||!/^\d+$/.test(p.play_id)||typeof p.userlink!=='string'||p.userlink.length>2048)unsupportedFeature('drpy_media_unresolved');
   var now=String(Date.now()),sign=CryptoJS.HmacSHA256(p.play_id+':'+now+':'+p.video,p.video).toString().slice(0,32),key='0';
   if(p.userlink&&p.userlink!=='0'){
    var inputBytes=CryptoJS.enc.Utf8.parse(p.userlink),keyBytes=CryptoJS.enc.Utf8.parse(cfg.playKey),words=[];
    for(var i=0;i<inputBytes.sigBytes;i++){
     var a=(inputBytes.words[i>>>2]>>>(24-(i%4)*8))&255,b=(keyBytes.words[(i%keyBytes.sigBytes)>>>2]>>>(24-((i%keyBytes.sigBytes)%4)*8))&255;
     words[i>>>2]=(words[i>>>2]||0)|((a^b)<<(24-(i%4)*8));
    }
    key=CryptoJS.enc.Base64.stringify(CryptoJS.lib.WordArray.create(words,inputBytes.sigBytes)).replace(/\+/g,'-').replace(/\//g,'_');
   }
   var path='/video/play?p='+encodeURIComponent(p.play_id)+'&v='+encodeURIComponent(p.video)+'&q=1080&s='+sign+'&t='+now+'&k='+encodeURIComponent(key);
   var body=this._get(path),doc;try{doc=JSON.parse(body);}catch(e){unsupportedFeature('drpy_media_unresolved');}
   var list=doc&&doc.data&&doc.data.quality_urls;if(!Array.isArray(list)||!list.length)unsupportedFeature('drpy_media_unresolved');
   var media=this._address(list[list.length-1].url);return {parse:0,url:media.url};
  }
 };
 return 'var cfg='+JSON.stringify(config)+';\nvar rule='+serialize(rule)+';';
};
