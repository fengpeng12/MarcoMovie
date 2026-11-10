// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
'use strict';
// App-owned protocol adapter. Origins are extracted from a reviewed user import.
function serialize(value) {
  if (typeof value === 'function') return value.toString();
  if (Array.isArray(value)) return '[' + value.map(serialize).join(',') + ']';
  if (value && typeof value === 'object') return '{' + Object.entries(value).map(([k, v]) => JSON.stringify(k) + ':' + serialize(v)).join(',') + '}';
  return JSON.stringify(value);
}
module.exports = function aueteRule(config) {
  if (!config || !/^https?:\/\//.test(config.origin) || !/^https?:\/\//.test(config.mediaBase)) throw Error('endpoint configuration required');
  const filters = {
    Movie: [['喜剧片','xjp'],['动作片','dzp'],['爱情片','aqp'],['科幻片','khp'],['恐怖片','kbp'],['惊悚片','jsp'],['战争片','zzp'],['剧情片','jqp']],
    Tv: [['美剧','oumei'],['韩剧','hanju'],['日剧','riju'],['泰剧','yataiju'],['网剧','wangju'],['台剧','taiju'],['国产','neidi'],['港剧','tvbgj']],
    Zy: [['国综','guozong'],['韩综','hanzong'],['美综','meizong']],
    Dm: [['动画','donghua'],['日漫','riman'],['国漫','guoman'],['美漫','meiman']],
    qita: [['纪录片','Jlp'],['经典片','Jdp'],['经典剧','Jdj'],['网大电影','wlp'],['国产老电影','laodianying']],
  };
  const rule = {
    title:'Auete', host:config.origin, homeUrl:'/',
    url:'/fyclass/fyfilterindexfypage.html[/fyclass/fyfilterindex.html]',
    filter_url:'{% if fl.type %}{{fl.type}}/{% endif %}',
    searchUrl:'/auete4so.php?page=fypage',
    searchable:2, quickSearch:1, filterable:1, limit:20, timeout:8000,
    headers:{'User-Agent':config.userAgent,'Accept-Language':'zh-CN,zh;q=0.8,en;q=0.2'},
    filter:Object.fromEntries(Object.entries(filters).map(([key, values]) => [key,
      [{key:'type',name:'分类',value:[{n:'全部',v:''},...values.map(([n,v])=>({n,v}))]}]])),
    预处理:'js:rule._init();',
    推荐:'js:VODS=rule._list(pdfa(rule._homeHtml,"ul.threadlist")[0]||"");',
    一级:'js:VODS=rule._list(rule._get(rule._categoryUrl(input,MY_FL)));',
    搜索:'js:VODS=rule._list(rule._get("/auete4so.php?searchword="+encodeURIComponent(KEY)+"&page="+MY_PAGE));',
    二级:'js:VOD=rule._detail(input);',
    play_parse:true,lazy:'js:input=rule._play(input);',
    _address:function(value,base){
      if(typeof value!=='string'||!value||/[\x00-\x1f\x7f\\]/.test(value))unsupportedFeature('drpy_media_protocol');
      var normalized;
      try{normalized=joinUrl(base||cfg.origin,value);}catch(e){unsupportedFeature('drpy_media_protocol');}
      var match=/^(https?):\/\/([^/?#]+)([^?#]*)(?:[?#]|$)/i.exec(normalized);
      if(!match||match[2].indexOf('@')!==-1)unsupportedFeature('drpy_media_protocol');
      return {url:normalized,origin:match[1].toLowerCase()+'://'+match[2].toLowerCase(),pathname:match[3]||'/'};
    },
    _catalogUrl:function(value){
      var address=this._address(value);
      if(address.origin!==this._address(cfg.origin).origin)unsupportedFeature('drpy_source_origin');
      return address.url;
    },
    _header:function(headers,name){
      var key=Object.keys(headers||{}).find(function(key){return key.toLowerCase()===name;});
      return key?String(headers[key]):'';
    },
    _validCookie:function(c){
      return c&&c.owner===this._address(cfg.origin).origin&&typeof c.secure==='boolean'&&
        typeof c.name==='string'&&/^[!#$%&'*+.^_`|~0-9a-z-]+$/i.test(c.name)&&
        typeof c.value==='string'&&c.value.length<=8192&&!/[\x00-\x20\x7f;,]/.test(c.value)&&
        typeof c.path==='string'&&c.path.startsWith('/')&&c.path.length<=8192&&!/[\x00-\x1f\x7f]/.test(c.path)&&
        (c.expires===null||(typeof c.expires==='number'&&Number.isFinite(c.expires)&&c.expires>Date.now()));
    },
    _receiveCookies:function(target,headers){
      var self=this,before=JSON.stringify(this._cookies);
      this._cookies=this._cookies.filter(function(c){return self._validCookie(c);});
      this._header(headers,'set-cookie').split(/\r?\n|,(?=\s*[^;,=\s]+\s*=)/).forEach(function(field){
        var parts=field.split(';'),first=parts.shift(),equal=first.indexOf('=');
        if(equal<1)return;
        var c={owner:target.origin,name:first.slice(0,equal).trim(),value:first.slice(equal+1).trim(),
          path:target.pathname.slice(0,target.pathname.lastIndexOf('/'))||'/',secure:false,expires:null};
        var domain='',maxAge=null;
        parts.forEach(function(part){
          var pair=part.trim().split('='),key=pair.shift().toLowerCase(),value=pair.join('=').trim();
          if(key==='domain')domain=value.replace(/^\./,'').toLowerCase();
          if(key==='path'&&value.startsWith('/'))c.path=value;
          if(key==='secure')c.secure=true;
          if(key==='max-age'&&/^-?\d+$/.test(value))maxAge=Number(value);
          if(key==='expires'){var date=Date.parse(value);if(Number.isFinite(date))c.expires=date;}
        });
        var host=target.origin.replace(/^https?:\/\//,'').replace(/:\d+$/,'');
        if(domain&&domain!==host&&!host.endsWith('.'+domain))return;
        if(c.secure&&!target.origin.startsWith('https:'))return;
        if(maxAge!==null)c.expires=maxAge<=0?0:Date.now()+Math.min(maxAge,31536000)*1000;
        if(!/^[!#$%&'*+.^_`|~0-9a-z-]+$/i.test(c.name)||/[\x00-\x20\x7f;,]/.test(c.value)||c.value.length>8192)return;
        self._cookies=self._cookies.filter(function(old){return old.owner!==c.owner||old.path!==c.path||old.name!==c.name;});
        if(self._validCookie(c))self._cookies.push(c);
      });
      this._cookies=this._cookies.slice(-64);
      if(JSON.stringify(this._cookies).length>96*1024)unsupportedFeature('drpy_storage_limit');
      if(JSON.stringify(this._cookies)!==before)local.set('auete-v1','cookies',this._cookies);
    },
    _send:function(value,options){
      var self=this,target=this._address(this._catalogUrl(value)),opts=options||{};
      var headers=Object.assign({},this.headers,opts.headers||{});
      var cookies=this._cookies.filter(function(c){return self._validCookie(c)&&
        (!c.secure||target.origin.startsWith('https:'))&&
        (target.pathname===c.path||target.pathname.startsWith(c.path.endsWith('/')?c.path:c.path+'/'));
      }).sort(function(a,b){return b.path.length-a.path.length;});
      if(cookies.length)headers.Cookie=cookies.map(function(c){return c.name+'='+c.value;}).join('; ');
      var response;
      var requestOptions=Object.assign({},opts,{headers:headers,timeout:8000,redirect:0});
      delete requestOptions.redirected;
      try{response=req(target.url,requestOptions);}catch(e){unsupportedFeature('drpy_source_unavailable');}
      if(!response||typeof response.content!=='string')unsupportedFeature('drpy_source_unavailable');
      this._receiveCookies(target,response.headers);
      if([301,302,303,307,308].includes(response.code)){
        var next=this._address(this._header(response.headers,'location'),target.url);
        if(next.origin!==target.origin||opts.redirected)unsupportedFeature('drpy_source_unavailable');
        // The verification caller reissues its original search after POST. Never
        // replay a submitted code or forward a session to a different origin.
        if(opts.method==='POST'){
          if(![302,303].includes(response.code)||next.pathname!=='/auete4so.php')unsupportedFeature('drpy_source_unavailable');
          return response;
        }
        return this._send(next.url,Object.assign({},opts,{redirected:true}));
      }
      if(response.code<200||response.code>=300)unsupportedFeature('drpy_source_unavailable');
      return response;
    },
    _verificationForm:function(html,referer){
      var $=DRPYDeps.cheerio.load(html,{xml:{xmlMode:false,decodeEntities:true}},false);
      var fields=$('input[name="validate"]'),images=$('img[src*="vdimgck"]');
      if(!fields.length||!images.length)return null;
      var form=fields.first().closest('form'),word=form.find('input[type="hidden"][name="searchword"]');
      var address=this._address(this._catalogUrl(referer));
      var action=this._address(form.attr('action')||'',address.url);
      var image=this._address(form.find('img[src*="vdimgck"]').first().attr('src')||'',address.url);
      if(fields.length!==1||word.length!==1||String(form.attr('method')).toLowerCase()!=='post'||
        address.pathname!=='/auete4so.php'||action.origin!==address.origin||action.pathname!==address.pathname||
        !/[?&]scheckAC=check(?:&|$)/.test(action.url)||image.origin!==address.origin||image.pathname!=='/include/vdimgck.php'||
        typeof word.val()!=='string'||word.val().length>2048)unsupportedFeature('drpy_verification_unavailable');
      return {referer:address.url,action:action.url,image:image.url,word:word.val()};
    },
    _get:function(value){
      var address=this._catalogUrl(value),html=this._send(address).content;
      var form=this._verificationForm(html,address);
      if(form){
        this._challenge=null;this._verification=form;local.set('auete-v1','verification',form);
        unsupportedFeature('drpy_verification_required');
      }
      return html;
    },
    _verificationAction:function(raw){
      var input;try{input=JSON.parse(raw);}catch(e){unsupportedFeature('drpy_action_invalid');}
      if(!input||input.type!=='verification')unsupportedFeature('drpy_action_invalid');
      var pending=this._verification;
      if(!pending||typeof pending.referer!=='string')unsupportedFeature('drpy_verification_unavailable');
      if(input.operation==='challenge'){
        this._challenge=null;
        // Refresh the real form as well as its PHP session, including after a
        // worker restart. The form's hidden search text belongs to this search.
        var html=this._send(this._catalogUrl(pending.referer)).content;
        pending=this._verificationForm(html,pending.referer);
        if(!pending)unsupportedFeature('drpy_verification_unavailable');
        this._verification=pending;local.set('auete-v1','verification',pending);
        var image=this._send(pending.image+(pending.image.indexOf('?')<0?'?':'&')+'get='+Date.now(),
          {buffer:2,headers:{Referer:pending.referer}});
        var mime=this._header(image.headers,'content-type').split(';')[0].trim().toLowerCase();
        if(!['image/png','image/jpeg','image/webp','image/gif'].includes(mime)||image.content.length>350000||
          !/^[A-Za-z0-9+/]+={0,2}$/.test(image.content))unsupportedFeature('drpy_verification_unavailable');
        this._challenge={id:Date.now().toString(36)+Math.random().toString(36).slice(2),until:Date.now()+180000};
        return {type:'image',id:this._challenge.id,mime:mime,imageBase64:image.content};
      }
      if(input.operation==='submit'){
        if(!this._challenge||this._challenge.id!==input.id||this._challenge.until<Date.now()||
          typeof input.code!=='string'||!/^[A-Za-z0-9]{4,6}$/.test(input.code))unsupportedFeature('drpy_action_invalid');
        var response=this._send(pending.action,{method:'POST',
          data:'validate='+encodeURIComponent(input.code)+'&searchword='+encodeURIComponent(pending.word),
          headers:{'Content-Type':'application/x-www-form-urlencoded; charset=UTF-8',
            Referer:pending.referer,Origin:this._address(cfg.origin).origin}});
        if(this._verificationForm(response.content,pending.referer))return {verified:false};
        var retry=this._send(pending.referer).content;
        if(this._verificationForm(retry,pending.referer))return {verified:false};
        // A 200 error page is not evidence that the protected search succeeded.
        if(!this._list(retry).length&&!pdfa(retry,'ul.threadlist').length)unsupportedFeature('drpy_verification_unavailable');
        this._challenge=null;this._verification=null;local.delete('auete-v1','verification');
        return {verified:true};
      }
      unsupportedFeature('drpy_action_invalid');
    },
    _categoryUrl:function(value,extend){
      var url=this._catalogUrl(value),address=this._address(url);
      var parts=/^\/(Movie|Tv|Zy|Dm|qita)\/(?:([^/]+)\/)?(index(?:[1-9]\d*)?\.html)$/.exec(address.pathname);
      if(!parts)unsupportedFeature('drpy_filter_not_supported');
      extend=extend||{};
      function active(value){return value!==undefined&&value!==null&&String(value).trim()!==''&&String(value).trim()!=='全部';}
      Object.keys(extend).forEach(function(key){if(key!=='type'&&key!=='class'&&active(extend[key]))unsupportedFeature('drpy_filter_not_supported');});
      var pathValue;try{pathValue=parts[2]?decodeURIComponent(parts[2]):'';}catch(e){unsupportedFeature('drpy_filter_not_supported');}
      var choices=(this.filter[parts[1]]||[]).filter(function(item){return item.key==='type';});
      var values=choices.length?choices[0].value:[],chosen='';
      [pathValue,extend.type,extend['class']].filter(active).forEach(function(selected){
        selected=String(selected).trim();
        var matches=values.filter(function(item){return item.v&&(selected===item.v||selected===item.n||selected===item.n.replace(/片$/,''));});
        if(matches.length!==1||chosen&&chosen!==matches[0].v)unsupportedFeature('drpy_filter_not_supported');
        chosen=matches[0].v;
      });
      return this._catalogUrl('/'+parts[1]+'/'+(chosen?chosen+'/':'')+parts[3]);
    },
    _init:function(){
      var html,seen={},self=this;
      this._cookies=local.get('auete-v1','cookies')||[];
      if(!Array.isArray(this._cookies))this._cookies=[];
      this._verification=local.get('auete-v1','verification');this._challenge=null;
      __drpy.action=function(raw){return self._verificationAction(raw);};
      html=this._get(cfg.origin);
      this._homeHtml=html;
      var categories=pdfa(html,'ul.navbar-nav > li a').map(function(a){
        var match=/\/(Movie|Tv|Zy|Dm|qita)\/index\.html(?:[?#]|$)/.exec(pdfh(a,'a&&href'));
        if(!match||seen[match[1]])return null;seen[match[1]]=true;
        return {id:match[1],name:pdfh(a,'a&&Text')};
      }).filter(Boolean);
      if(!categories.length)unsupportedFeature('drpy_source_unavailable');
      this.class_url=categories.map(function(c){return c.id;}).join('&');
      this.class_name=categories.map(function(c){return c.name;}).join('&');
    },
    _list:function(html){
      if(pdfa(html,'input[name="validate"]').length&&pdfa(html,'img[src*="vdimgck"]').length)unsupportedFeature('drpy_verification_required');
      var self=this,seen={};
      return pdfa(html,'li').map(function(item){
        var href=pdfh(item,'h2 a&&href'),match=/\/(\w+\/\w+\/\w+)\/(?:[?#]|$)/.exec(href);
        if(!match||seen[match[1]])return null;seen[match[1]]=true;
        var name=pdfh(item,'h2 a&&title')||pdfh(item,'h2 a&&Text');
        if(!name)return null;
        return {vod_id:self._catalogUrl('/'+match[1]+'/'),vod_name:name,
          vod_pic:pd(item,'a.pic img&&src',cfg.origin),vod_remarks:pdfh(item,'span.hdtag&&Text')};
      }).filter(Boolean);
    },
    _detail:function(url){
      var html=this._get(this._catalogUrl(url)),self=this;
      var result={vod_id:url,vod_name:pdfh(html,'h1.detail-title&&Text').replace(/[《》]/g,'')||pdfh(html,'div.detail-main-card&&data-pname'),
        vod_pic:pd(html,'div.detail-poster img&&src',cfg.origin)||pd(html,'div.detail-main-card&&data-ppic',cfg.origin),
        vod_content:pdfh(html,'p.detail-des&&Text'),vod_play_from:'',vod_play_url:''};
      var labels={'类型':'type_name','导演':'vod_director','主演':'vod_actor','地区':'vod_area','年代':'vod_year','备注':'vod_remarks'};
      pdfa(html,'div.message p').forEach(function(p){
        var label=pdfh(p,'span.detail-label&&Text').replace(/[：:\s]/g,''),key=labels[label];
        if(key)result[key]=pdfh(p,'b&&Text')||pdfh(p,'p&&Text').replace(pdfh(p,'span.detail-label&&Text'),'').trim();
      });
      var lines=[],groups=[];
      pdfa(html,'div.play-card#player_list').forEach(function(card){
        var name=pdfh(card,'div.card-header span b&&Text').replace(/^.*[：:]\s*/,'');
        var episodes=pdfa(card,'ul.episode-list li > a').map(function(a){
          var href=pdfh(a,'a&&href');
          if(!/\/\w+\/\w+\/\w+\/play-\d+-\d+\.html(?:[?#]|$)/.test(href))return '';
          return pdfh(a,'a&&Text')+'$'+self._catalogUrl(href);
        }).filter(Boolean);
        if(name&&episodes.length){lines.push(name);groups.push(episodes.join('#'));}
      });
      result.vod_play_from=lines.join('$$$');result.vod_play_url=groups.join('$$$');return result;
    },
    _quoted:function(value){
      if(value[0]==='"')return JSON.parse(value);
      if(value[0]!=="'"||value[value.length-1]!=="'")throw Error('literal');
      return value.slice(1,-1).replace(/\\(u[\da-fA-F]{4}|[\\/'"])/g,function(_,escape){
        return escape[0]==='u'?String.fromCharCode(parseInt(escape.slice(1),16)):escape;
      });
    },
    _play:function(url){
      var html=this._get(this._catalogUrl(url)),scripts=pdfa(html,'div > script'),resolved='';
      for(var i=0;i<scripts.length&&!resolved;i++){
        var text=pdfh(scripts[i],'script&&Html');
        var pattern=/(?:^|[;\s])(?:var\s+)?now\s*=\s*(base64(?:decode)?\(\s*['"]?[A-Za-z\d+/_=-]+['"]?\s*\)|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')\s*;/g,match;
        while((match=pattern.exec(text))&&!resolved){
          var value=match[1],decoded;
          if(/^base64(?:decode)?\(/.test(value)){
            var token=value.replace(/^base64(?:decode)?\(\s*['"]?/,'').replace(/['"]?\s*\)$/,'').replace(/-/g,'+').replace(/_/g,'/');
            if(token.length>8192||token.length%4===1)continue;
            while(token.length%4)token+='=';decoded=base64Decode(token);
          }else{try{decoded=this._quoted(value);}catch(e){continue;}}
          if(/^https?:\/\//i.test(decoded))resolved=this._address(decoded).url;
          else if(!/^[a-z][a-z\d+.-]*:/i.test(decoded)&&/\.m3u8(?:[?#]|$)/i.test(decoded))resolved=this._address(decoded,cfg.mediaBase).url;
          else unsupportedFeature('drpy_media_protocol');
        }
      }
      if(!resolved)unsupportedFeature('drpy_media_unresolved');
      return {parse:0,url:resolved,header:{'User-Agent':cfg.userAgent}};
    },
  };
  return 'var cfg='+JSON.stringify(config)+';\nvar rule='+serialize(rule)+';';
};
