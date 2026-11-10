// Synthetic fixture. Never bundled into the production application.
const fs=require('node:fs'),path=require('node:path');
exports.start=async()=>{
  const file=path.join(process.env.NODE_PATH,'probe-starts.txt');
  const starts=Number(fs.existsSync(file)?fs.readFileSync(file,'utf8'):0)+1;
  fs.writeFileSync(file,String(starts));
  const server=catServerFactory(async(req,res)=>{
    const base='http://127.0.0.1:'+server.address().port;
    if(req.url==='/t4'){
      res.setHeader('Content-Type','application/json');
      // Keep the fixture's loopback origin out of the outer router's ordinary
      // playback URL rewriting. Used only by this simulator test app.
      res.end(JSON.stringify({starts,fyOrigin:Buffer.from(base).toString('base64'),sites:[{key:'fixture',name:'Fixture',type:4,api:base+'/api/demo'}]}));
    }else if(req.url.startsWith('/captcha.php')){
      if(req.method==='GET'){
        res.setHeader('Set-Cookie',['sid=fixture; Path=/','unused=no; Path=/unused']);
        res.setHeader('Content-Type','image/png');
        res.end(Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lWQAAAAASUVORK5CYII=','base64'));
      }else{
        let body='';for await(const chunk of req)body+=chunk;
        const ok=new URLSearchParams(body).get('check')==='AB12'&&String(req.headers.cookie).includes('sid=fixture');
        if(ok)res.setHeader('Set-Cookie','verified=yes; Path=/');
        res.end(JSON.stringify({code:ok?1:0}));
      }
    }else if(req.url==='/fy-media.m3u8'){
      res.setHeader('Content-Type','application/vnd.apple.mpegurl');res.end('#EXTM3U\n#EXT-X-VERSION:3\n');
    }else if(req.url.startsWith('/player/?')){
      res.setHeader('Set-Cookie','parser=fixture; Path=/player');res.end('<div data-te="fixture-token"></div>');
    }else if(req.url==='/player/mplayer.php'){
      let body='';for await(const chunk of req)body+=chunk;
      const form=new URLSearchParams(body);
      if(form.get('url')!=='opaque media' || form.get('token')!=='fixture-token' || !String(req.headers.cookie).includes('parser=fixture')){
        res.statusCode=403;res.end();return;
      }
      res.end(JSON.stringify({data:{url:base+'/fy-media.m3u8'}}));
    }else if(req.url==='/' || req.url.startsWith('/cupfox-') || req.url.startsWith('/detail/') || req.url.startsWith('/play/')){
      if(!String(req.headers.cookie).includes('verified=yes')){
        res.end('<h1>验证码</h1><img src="/captcha.php"><input name="check">');return;
      }
      if(req.url.startsWith('/detail/')){
        res.end('<h3 class="slide-info-title">FY 本机影片</h3><div class="anthology-tab"><div class="swiper-slide" aria-label="1 / 1">线路 A</div></div><div class="anthology-list-box"><a href="/play/123-1-2.html">第二集</a><a href="/play/123-1-1.html">第一集</a></div>');
      }else if(req.url.startsWith('/play/')){
        res.end('<script>var player_aaaa={"url":"opaque media","from":"co"};</script>');
      }else{
        res.end('<a class="public-list-exp" href="/detail/123.html" title="FY 本机影片"><img data-src="/poster.png"></a><span>2/4页</span>');
      }
    }else if(req.url.startsWith('/api/cms')){
      const url=new URL(req.url,base);
      if(url.pathname==='/api/cms/media.m3u8'){
        res.setHeader('Content-Type','application/vnd.apple.mpegurl');res.end('#EXTM3U\n#EXT-X-VERSION:3\n');return;
      }
      res.setHeader('Content-Type','application/json');
      res.end(JSON.stringify({class:[{type_id:'1',type_name:'电影'}],page:2,pagecount:3,limit:1,total:3,
        list:[{vod_id:url.searchParams.get('ids')||'opaque/$#?',vod_name:'T4 本机影片',vod_play_from:'one',vod_play_url:'第一集$'+base+'/api/cms/media.m3u8'}]}));
    }else if(req.url==='/api/fetch'){
      const response=await fetch(base+'/api/bytes');res.end(Buffer.from(await response.arrayBuffer()));
    }else if(req.url==='/api/bytes'){res.end(Buffer.from([0,1,255,42]));}
    else if(req.url==='/api/play'){
      res.setHeader('Content-Type','application/json');
      res.end(JSON.stringify({url:base+'/spider/demo/3/proxy/token/hls/index.m3u8?sig=fixture'}));
    }else if(req.url==='/spider/demo/3/proxy/token/hls/index.m3u8?sig=fixture'){
      res.setHeader('Content-Type','application/vnd.apple.mpegurl');
      res.end('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="../key?sig=fixture"\n../key?sig=fixture\n');
    }else if(req.url==='/spider/demo/3/proxy/token/key?sig=fixture'){
      res.setHeader('Content-Type','application/octet-stream');res.end(Buffer.from([0,1,255,42]));
    }
    else{res.statusCode=404;res.end();}
  });
  await new Promise(resolve=>server.listen(9321,'0.0.0.0',resolve));
};
