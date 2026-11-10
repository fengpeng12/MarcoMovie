// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
'use strict';
// Protocol adapter for one reviewed imported plugin; all endpoints are parameters.
module.exports = function dm84Rule(config) {
  if (!config || !/^https?:\/\//.test(config.origin) || !/^https?:\/\//.test(config.parser)) throw Error('endpoint configuration required');
  return `var cfg=${JSON.stringify(config)};
var rule={
  title:'Dm84',host:cfg.origin,homeUrl:'/',
  detailUrl:'/v/fyid',url:'/show-fyclass--fyfilter-fypage.html',
  filter_url:'{{fl.by|default("time",true)}}-{{fl.type|default("",true)}}--{{fl.year|default("",true)}}',
  searchUrl:'/s----------.html?wd=**',searchable:2,quickSearch:1,filterable:1,
  headers:{'User-Agent':cfg.userAgent,'Accept-Language':'zh-CN,zh;q=0.9,en;q=0.8'},
  timeout:8000,limit:30,
  预处理:'js:rule._init();',
  推荐:'js:VODS=rule._list(rule._homeHtml||request(input));',
  一级:'js:VODS=rule._list(request(input));',
  搜索:'js:VODS=rule._list(request(input));',
  二级:'js:VOD=rule._detail(input);',
  play_parse:true,lazy:'js:input=rule._play(input);',
  _list:function(html){return pdfa(html,'div.item').map(function(item){
    var href=pdfh(item,'a.title&&href');
    return {vod_id:href.split('/').pop(),vod_name:pdfh(item,'a.title&&Text'),
      vod_pic:pd(item,'a.cover&&data-bg',cfg.origin),vod_remarks:pdfh(item,'span.desc&&Text')};
  }).filter(function(item){return item.vod_id&&item.vod_name;});},
  _init:function(){
    var html;
    try{html=request(cfg.origin);}catch(e){unsupportedFeature('drpy_source_unavailable');}
    this._homeHtml=html;
    var categories=pdfa(html,'ul.nav_row > li > a').map(function(item){
      var href=pdfh(item,'a&&href'),match=/\\/list-(\\d+)\\.html/.exec(href);
      return match?{id:match[1],name:pdfh(item,'a&&Text')}:null;
    }).filter(Boolean);
    if(!categories.length)unsupportedFeature('drpy_source_unavailable');
    this.class_name=categories.map(function(c){return c.name;}).join('&');
    this.class_url=categories.map(function(c){return c.id;}).join('&');
    this.filter={};var self=this;
    categories.forEach(function(c){
      try{
        var groups=pdfa(request(joinUrl(cfg.origin,'/list-'+c.id+'.html'),{timeout:2000}),'ul.list_filter > li > div');
        if(groups.length<3)throw new Error('Dm84 category filter groups are missing');
        self.filter[c.id]=['type','year','by'].map(function(key,index){
          return {key:key,name:['类型','时间','排序'][index],value:pdfa(groups[index],'a').map(function(a){
            var text=pdfh(a,'a&&Text');var value=text;
            if(key==='by')value=text.replace('按时间','time').replace('按人气','hits').replace('按评分','score');
            if(text==='全部')value='';
            return {n:text.replace('按',''),v:value};
          }).filter(function(v){return v.n;})};
        });
      }catch(e){
        // A missing optional filter page must not discard working catalog data.
        self.filter[c.id]=[];
      }
    });
  },
  _detail:function(url){
    var html=request(url),tabs=pdfa(html,'ul.tab_control > li'),groups=pdfa(html,'ul.play_list');
    var from=[],episodes=[];
    tabs.forEach(function(tab,index){
      if(!groups[index])return;
      var list=pdfa(groups[index],'a').map(function(a){return pdfh(a,'a&&Text')+'$'+pd(a,'a&&href',cfg.origin);});
      if(list.length){from.push(pdfh(tab,'li&&Text'));episodes.push(list.join('#'));}
    });
    return {vod_id:url,vod_name:pdfh(html,'h1.v_title&&Text'),vod_pic:pdfh(html,'meta[property="og:image"]&&content'),
      vod_area:pdfh(html,'meta[name="og:video:area"]&&content'),vod_year:pdfh(html,'meta[name="og:video:release_date"]&&content'),
      type_name:pdfh(html,'meta[name="og:video:class"]&&content'),vod_actor:pdfh(html,'meta[name="og:video:actor"]&&content'),
      vod_director:pdfh(html,'meta[name="og:video:director"]&&content'),vod_content:pdfh(html,'meta[property="og:description"]&&content'),
      vod_remarks:pdfh(html,'p.v_desc > span.desc&&Text'),vod_play_from:from.join('$$$'),vod_play_url:episodes.join('$$$')};
  },
  _address:function(value){
    if(typeof value!=='string'||!value||/[\\x00-\\x20\\x7f\\\\]/.test(value))unsupportedFeature('drpy_media_protocol');
    var normalized;
    try{normalized=joinUrl(cfg.origin,value);}catch(e){unsupportedFeature('drpy_media_protocol');}
    var match=/^(https?):\\/\\/([^/?#]+)([^?#]*)(?:[?#]|$)/i.exec(normalized);
    if(!match||match[2].indexOf('@')!==-1)unsupportedFeature('drpy_media_protocol');
    return {url:normalized,origin:match[1].toLowerCase()+'://'+match[2].toLowerCase(),pathname:match[3]||'/'};
  },
  _play:function(url){
    var page=this._address(url),html=request(page.url),iframe=pdfh(html,'iframe&&src'),resolved='';
    var parser=this._address(cfg.parser);
    // The parser may itself have a media URL in its query. Its exact origin
    // takes precedence over extension detection; never run page scripts.
    if(iframe){
      var frame=this._address(iframe);
      if(frame.origin===parser.origin)html=request(frame.url);
      else if(/\\.(?:m3u8|mp4)$/i.test(frame.pathname))resolved=frame.url;
    }
    if(!resolved){
      var scripts=pdfa(html,'script');
      for(var i=0;i<scripts.length;i++){
        var text=pdfh(scripts[i],'script&&Html').trim();
        if(text.indexOf('window.__HHJX_BOOTSTRAP__')!==0&&text.indexOf('var player_')!==0)continue;
        var start=text.indexOf('{'),end=text.lastIndexOf('}');
        if(start<0||end<=start)continue;
        var data=JSON.parse(text.substring(start,end+1));
        var response=req(parser.url,{method:'POST',headers:{'User-Agent':cfg.userAgent,'Origin':parser.origin,
          'Content-Type':'application/json'},body:JSON.stringify({url:data.url,t:Number(data.t)||0,key:data.key,client_fallback:false}),timeout:8000});
        if(response.code!==200)throw new Error('Dm84 parser HTTP '+response.code);
        resolved=JSON.parse(response.content).url||'';
        if(resolved)break;
      }
    }
    if(!resolved)unsupportedFeature('drpy_media_unresolved');
    return {parse:0,url:this._address(resolved).url,header:{'User-Agent':cfg.userAgent}};
  }
};`;
};
