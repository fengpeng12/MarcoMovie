// Exercise the production QuickJS bridge and Python assets on the iOS CPU.
#import <Foundation/Foundation.h>
#include "quickjs/quickjs.h"
#include <cstring>
extern "C" {
  JSRuntime *jsNewRuntime(void *(*channel)(JSContext *, size_t, void *), int64_t timeout);
  JSContext *jsNewContext(JSRuntime *);
  void jsSetOperationTimeout(JSRuntime *, int64_t timeout);
  JSValue *jsEval(JSContext *, const char *, size_t, const char *, int32_t);
  int32_t jsExecutePendingJob(JSRuntime *);
  void jsFreeValue(JSContext *, JSValue *, int32_t);
  void jsFreeContext(JSContext *);
  void jsFreeRuntime(JSRuntime *);
}
static void *channel(JSContext *ctx, size_t kind, void *value) { return nullptr; }
static void evaluate(JSContext *ctx, NSString *source, int flags=JS_EVAL_TYPE_GLOBAL, NSString *name=@"ios-fixture.js") {
  const char *code=source.UTF8String;
  JSValue *value=jsEval(ctx,code,strlen(code),name.UTF8String,flags);
  BOOL failed=JS_IsException(*value);jsFreeValue(ctx,value,1);
  if(failed){
    JSValue error=JS_GetException(ctx);const char *text=JS_ToCString(ctx,error);
    NSString *message=text?[NSString stringWithUTF8String:text]:@"unknown";
    if(text)JS_FreeCString(ctx,text);JS_FreeValue(ctx,error);
    @throw [NSException exceptionWithName:@"QuickJsProbe" reason:[NSString stringWithFormat:@"quickjs_evaluation [%@]: %@",name,message] userInfo:nil];
  }
}
static BOOL boolean(JSContext *ctx, NSString *source) {
  const char *code=source.UTF8String;
  JSValue *value=jsEval(ctx,code,strlen(code),"ios-assert.js",JS_EVAL_TYPE_GLOBAL);
  BOOL result=!JS_IsException(*value)&&JS_ToBool(ctx,*value)==1;
  jsFreeValue(ctx,value,1);return result;
}
static NSString *diagnostic(JSContext *ctx, NSString *source) {
  const char *code=source.UTF8String;
  JSValue *value=jsEval(ctx,code,strlen(code),"ios-diagnostic.js",JS_EVAL_TYPE_GLOBAL);
  const char *text=JS_IsException(*value)?nullptr:JS_ToCString(ctx,*value);
  NSString *result=text?[NSString stringWithUTF8String:text]:@"evaluation failed";
  if(text)JS_FreeCString(ctx,text);jsFreeValue(ctx,value,1);
  return result.length>8192?[result substringToIndex:8192]:result;
}
static NSString *literal(id value) {
  NSData *data=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingFragmentsAllowed error:nil];
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}
static void spiderOperation(JSContext *ctx, JSRuntime *rt, NSString *expression, NSString *resultName) {
  // Each production operation gets the same budget, including promise jobs.
  jsSetOperationTimeout(rt,8000);
  evaluate(ctx,[NSString stringWithFormat:@"__movieBeginCall(()=>%@);",expression],JS_EVAL_TYPE_GLOBAL,@"complete-spider-call.js");
  while(jsExecutePendingJob(rt)>0){}
  evaluate(ctx,[NSString stringWithFormat:@"globalThis.%@=__movieFinishCall();",resultName],JS_EVAL_TYPE_GLOBAL,@"complete-spider-result.js");
}
NSArray *runQuickJsProbe(NSString *assets) {
  NSMutableArray *checks=[NSMutableArray array];
  JSRuntime *rt=jsNewRuntime(channel,10000);JSContext *ctx=jsNewContext(rt);
  JS_SetMaxStackSize(rt,512*1024);JS_SetMemoryLimit(rt,48*1024*1024);
  @try {
    evaluate(ctx,@"globalThis.global=globalThis;globalThis.window=globalThis;globalThis.self=globalThis;globalThis.console={log(){},warn(){},error(){}};");
    evaluate(ctx,@"export const title='iOS 模块'; globalThis.moduleTitle=title;",JS_EVAL_TYPE_MODULE);
    while(jsExecutePendingJob(rt)>0){}
    [checks addObject:@{@"name":@"quickjs_native_es_module",@"passed":@(boolean(ctx,@"moduleTitle==='iOS 模块'"))}];
    NSString *dependencies=[NSString stringWithContentsOfFile:[assets stringByAppendingPathComponent:@"python-host/parser.js"] encoding:NSUTF8StringEncoding error:nil];
    if(!dependencies) @throw [NSException exceptionWithName:@"QuickJsProbe" reason:@"html_dependency_missing" userInfo:nil];
    evaluate(ctx,[@"globalThis.__moviePythonHtmlParser=function(){\n" stringByAppendingFormat:@"%@\nglobalThis.__moviePythonHtmlParser=()=>MoviePythonHtml;return MoviePythonHtml;};", dependencies],JS_EVAL_TYPE_GLOBAL,@"python-parser-loader.js");
    for(NSString *name in @[@"skulpt.min.js",@"skulpt-stdlib.js",@"compiled-modules.js",@"html.js",@"regex.js",@"json.js",@"io.js",@"spider.js"]){
      NSString *file=[[assets stringByAppendingPathComponent:@"python-host"] stringByAppendingPathComponent:name];
      NSString *source=[NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil];
      if(!source) @throw [NSException exceptionWithName:@"QuickJsProbe" reason:@"python_asset_missing" userInfo:nil];
      evaluate(ctx,source,JS_EVAL_TYPE_GLOBAL,name);
    }
    // HTTP response is synthetic here; the separate Node test uses a real socket.
    // Asset setup is not a Python operation. Start the same bounded operation
    // clock immediately before invoking it, as subsequent probes already do.
    jsSetOperationTimeout(rt,8000);
    NSDate *pythonCallStarted=[NSDate date];
    NSString *response=@"{\"list\":[{\"vod_id\":\"one\",\"vod_name\":\"Python HTTP\"}]}";
    NSString *encoded=[[response dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
    evaluate(ctx,[NSString stringWithFormat:@"globalThis.binaryBodySeen=false;globalThis.req=async(url,options={})=>{if(url.endsWith('/upload')){if(options.bodyBase64!=='AP+AQQ=='||'data' in options||'body' in options)throw Error('binary request bridge');binaryBodySeen=true;}return {code:200,url,headers:{'Content-Type':'application/json'},content:options.buffer===2?%@:%@};};",literal(encoded),literal(response)],JS_EVAL_TYPE_GLOBAL,@"python-request-fixture.js");
    NSString *python=@"import base64\nimport requests\nfrom helper import title\nfrom base.spider import Spider as Base\nclass Spider(Base):\n    def homeContent(self, filter):\n        jar=requests.Session().cookies\n        jar.set('sid','fixture',domain='fixture.invalid',path='/auth',secure=True)\n        cookie=list(jar)[0]\n        return {'list':[{'vod_id':'one','vod_name':title}], 'cookie_ok':cookie.name=='sid' and cookie.value=='fixture' and cookie.domain=='fixture.invalid' and cookie.path=='/auth' and cookie.secure and dict(jar)=={'sid':'fixture'}}\n    def searchContent(self, key, quick, pg='1'):\n        return self.fetch('https://fixture.invalid/data').json()\n    def playerContent(self, flag, id, vip):\n        if list(base64.urlsafe_b64decode('AP8q')) != [0,255,42]: raise ValueError('bytes')\n        requests.post('https://fixture.invalid/upload',data=bytes([0,255,128,65]))\n        return {'url':'https://fixture.invalid/video.mp4'}\n";
    python=[python stringByReplacingOccurrencesOfString:@"    def homeContent(self, filter):\n" withString:@"    def __init__(self):\n        self.boot_title = self.fetch('https://fixture.invalid/bootstrap').json()['list'][0]['vod_name']\n    def init(self, ext):\n        self.boot_ready = self.boot_title == 'Python HTTP'\n    def homeContent(self, filter):\n        assert self.boot_ready\n"];
    python=[python stringByAppendingString:@"\nfrom remotehelper import remote_title\nassert remote_title == 'native async helper'\n"];
    evaluate(ctx,[NSString stringWithFormat:@"globalThis.pythonRemoteReads=0;globalThis.py=createPythonSpider(%@,%@,async name=>{pythonRemoteReads++;return name==='remotehelper.py'?\"remote_title = 'native async helper'\":null;});globalThis.pyDone=false;globalThis.pyFailed=false;Promise.resolve(py.init('')).then(async()=>{globalThis.pyHome=await py.home(true);Sk.execStart-=9000;Sk.lastYield-=9000;globalThis.pySearch=await py.search('test',false,1);globalThis.pyPlay=await py.play('line','one',[]);pyDone=true;}).catch(error=>{globalThis.pyError=String(error);pyFailed=true;pyDone=true;});",literal(python),literal(@{@"helper.py":@"title='Python 本机模块'\n"})],JS_EVAL_TYPE_GLOBAL,@"python-bootstrap.js");
    NSDate *until=[NSDate dateWithTimeIntervalSinceNow:8];
    while(!boolean(ctx,@"pyDone")&&until.timeIntervalSinceNow>0){
      while(jsExecutePendingJob(rt)>0){} [NSThread sleepForTimeInterval:.001];
    }
    if(boolean(ctx,@"pyFailed")){
      JSValue global=JS_GetGlobalObject(ctx),error=JS_GetPropertyStr(ctx,global,"pyError");
      const char *text=JS_ToCString(ctx,error);
      NSString *message=text?[NSString stringWithUTF8String:text]:@"unknown";
      if(text)JS_FreeCString(ctx,text);JS_FreeValue(ctx,error);JS_FreeValue(ctx,global);
      @throw [NSException exceptionWithName:@"QuickJsProbe" reason:[@"python_execution: " stringByAppendingString:message] userInfo:nil];
    }
    [checks addObject:@{@"name":@"python_native_local_module",@"passed":@(boolean(ctx,@"pyDone&&!pyFailed&&pyHome.list[0].vod_name==='Python 本机模块'")),@"elapsed_ms":@(-pythonCallStarted.timeIntervalSinceNow*1000)}];
    [checks addObject:@{@"name":@"python_native_async_module",@"passed":@(boolean(ctx,@"pyDone&&!pyFailed&&pythonRemoteReads>0"))}];
    [checks addObject:@{@"name":@"python_native_async_constructor",@"passed":@(boolean(ctx,@"pyDone&&!pyFailed&&pyHome.list[0].vod_name==='Python 本机模块'"))}];
    [checks addObject:@{@"name":@"python_native_async_response",@"passed":@(boolean(ctx,@"pyDone&&!pyFailed&&pySearch.list[0].vod_name==='Python HTTP'"))}];
    [checks addObject:@{@"name":@"python_native_binary_play_result",@"passed":@(boolean(ctx,@"pyDone&&!pyFailed&&pyPlay.url==='https://fixture.invalid/video.mp4'"))}];
    [checks addObject:@{@"name":@"python_native_cookie_objects",@"passed":@(boolean(ctx,@"pyDone&&!pyFailed&&pyHome.cookie_ok===true"))}];
    [checks addObject:@{@"name":@"python_native_binary_request_bridge",@"passed":@(boolean(ctx,@"pyDone&&!pyFailed&&binaryBodySeen"))}];
    [checks addObject:@{@"name":@"python_native_renewed_operation_clock",@"passed":@(boolean(ctx,@"pyDone&&!pyFailed&&Sk.execLimit===8000&&pySearch.list[0].vod_name==='Python HTTP'"))}];
    for(NSString *contract in @[@"html",@"json",@"io",@"package"]) {
    NSString *htmlSource=[NSString stringWithContentsOfFile:[assets stringByAppendingPathComponent:[NSString stringWithFormat:@"python_%@_contract.py",contract]] encoding:NSUTF8StringEncoding error:nil];
    NSData *htmlExpectedData=[NSData dataWithContentsOfFile:[assets stringByAppendingPathComponent:[NSString stringWithFormat:@"python_%@_expected.json",contract]]];
    NSString *htmlExpectedText=htmlExpectedData?[[NSString alloc] initWithData:htmlExpectedData encoding:NSUTF8StringEncoding]:nil;
    NSDictionary *htmlExpected=htmlExpectedData?[NSJSONSerialization JSONObjectWithData:htmlExpectedData options:0 error:nil]:nil;
    NSUInteger expectedCount=[contract isEqualToString:@"html"]?21:[contract isEqualToString:@"json"]?28:[contract isEqualToString:@"io"]?29:65;
    if(!htmlSource||htmlExpected.count!=expectedCount) @throw [NSException exceptionWithName:@"QuickJsProbe" reason:[contract stringByAppendingString:@"_contract_fixture_missing"] userInfo:nil];
    jsSetOperationTimeout(rt,8000);
    // Keep the oracle's original UTF-8 text: Foundation's parsed string path
    // removes a leading U+FEFF inside an expected value on iOS. Re-serializing
    // that dictionary corrupts the BOM error case before the comparison.
    NSDictionary *packageFixture=@{};
    if([contract isEqualToString:@"package"]) {
      NSData *fixtureData=[NSData dataWithContentsOfFile:[assets stringByAppendingPathComponent:@"python_package_fixture.json"]];
      packageFixture=fixtureData?[NSJSONSerialization JSONObjectWithData:fixtureData options:0 error:nil]:nil;
      if(![packageFixture[@"modules"] isKindOfClass:NSDictionary.class]||![packageFixture[@"packageData"] isKindOfClass:NSDictionary.class])
        @throw [NSException exceptionWithName:@"QuickJsProbe" reason:@"python_package_fixture_missing" userInfo:nil];
    }
    evaluate(ctx,[NSString stringWithFormat:@"globalThis.htmlDone=false;globalThis.htmlError='';globalThis.htmlSpider=createPythonSpider(%@,%@,null,%@);Promise.resolve(htmlSpider.init('')).then(()=>htmlSpider.home(true)).then(value=>{globalThis.htmlResult=value;htmlDone=true;}).catch(error=>{htmlError=String(error);htmlDone=true;});globalThis.htmlExpected=%@;",literal(htmlSource),literal(packageFixture[@"modules"]?:@{}),packageFixture[@"packageData"]?literal(packageFixture[@"packageData"]):@"null",htmlExpectedText],JS_EVAL_TYPE_GLOBAL,@"python-oracle.js");
    until=[NSDate dateWithTimeIntervalSinceNow:8];
    while(!boolean(ctx,@"htmlDone")&&until.timeIntervalSinceNow>0){
      while(jsExecutePendingJob(rt)>0){} [NSThread sleepForTimeInterval:.001];
    }
    if([contract isEqualToString:@"json"]) [checks addObject:@{@"name":@"python_json_oracle_utf8_preserved",@"passed":@(boolean(ctx,@"htmlExpected.errors[11][0]==='\\ufeff{}'"))}];
    for(NSString *key in htmlExpected){
      NSString *condition=[NSString stringWithFormat:@"htmlDone&&!htmlError&&((actual,expected)=>typeof expected==='object'&&!Array.isArray(expected)&&expected!==null?Object.keys(expected).every(k=>JSON.stringify(actual[k])===JSON.stringify(expected[k])):JSON.stringify(actual)===JSON.stringify(expected))(htmlResult[%@],htmlExpected[%@])",literal(key),literal(key)];
      BOOL passed=boolean(ctx,condition);
      NSMutableDictionary *check=[@{@"name":[NSString stringWithFormat:@"python_native_%@_%@",contract,key],@"passed":@(passed)} mutableCopy];
      if(!passed) check[@"diagnostic"]=diagnostic(ctx,[NSString stringWithFormat:@"JSON.stringify({done:htmlDone,error:htmlError,actual:typeof htmlResult==='undefined'?null:htmlResult[%@],expected:htmlExpected[%@]})",literal(key),literal(key)]);
      [checks addObject:check];
    }
    }
    // Start this separate operation with its own budget, as the production host does.
    jsSetOperationTimeout(rt,8000);
    NSString *proxySource=@"from base.spider import Spider as Base\nclass Spider(Base):\n def init(self, ext): self.ticket='retained'\n def homeContent(self, filter): return [self.getProxyUrl({'ticket':'a b'}), self.proxyUrl({'ticket':'new'})]\n def localProxy(self, params):\n  assert self.ticket == 'retained' and params['range'] == 'bytes=1-2'\n  return [200,'application/octet-stream',bytes([0,255,128,65]),{'X-State':self.ticket}]\n";
    evaluate(ctx,[NSString stringWithFormat:@"globalThis.__movieProxyBase='http://127.0.0.1:8191/_spider/fixture/proxy?do=py&siteKey=native';globalThis.proxyDone=false;globalThis.proxyError='';globalThis.proxySpider=createPythonSpider(%@);Promise.resolve(proxySpider.init('')).then(()=>proxySpider.home(true)).then(value=>{globalThis.proxyUrls=value;return proxySpider.proxy({range:'bytes=1-2'});}).then(value=>{globalThis.proxyValue=value;proxyDone=true;}).catch(error=>{proxyError=String(error);proxyDone=true;});",literal(proxySource)],JS_EVAL_TYPE_GLOBAL,@"python-proxy.js");
    until=[NSDate dateWithTimeIntervalSinceNow:8];
    while(!boolean(ctx,@"proxyDone")&&until.timeIntervalSinceNow>0){
      while(jsExecutePendingJob(rt)>0){} [NSThread sleepForTimeInterval:.001];
    }
    [checks addObject:@{@"name":@"python_native_proxy_url_abis",@"passed":@(boolean(ctx,@"proxyDone&&!proxyError&&proxyUrls[0]===__movieProxyBase+'&ticket=a+b'&&proxyUrls[1]===__movieProxyBase+'&ticket=new'"))}];
    [checks addObject:@{@"name":@"python_native_proxy_binary_wire",@"passed":@(boolean(ctx,@"proxyDone&&!proxyError&&proxyValue[2]==='AP+AQQ=='&&proxyValue[4]===1"))}];
    [checks addObject:@{@"name":@"python_native_proxy_state_and_headers",@"passed":@(boolean(ctx,@"proxyDone&&!proxyError&&proxyValue[0]===200&&proxyValue[1]==='application/octet-stream'&&proxyValue[3]['X-State']==='retained'"))}];
    jsSetOperationTimeout(rt,8000);
    NSString *interop=[NSString stringWithContentsOfFile:[assets stringByAppendingPathComponent:@"js-host/module-interop.js"] encoding:NSUTF8StringEncoding error:nil];
    if(!interop) @throw [NSException exceptionWithName:@"QuickJsProbe" reason:@"module_interop_asset_missing" userInfo:nil];
    evaluate(ctx,interop,JS_EVAL_TYPE_GLOBAL,@"module-interop.js");
    jsSetOperationTimeout(rt,8000);
    evaluate(ctx,[NSString stringWithUTF8String:R"JS(
globalThis.completeConstructed = 0;
export default class CompleteSpider {
  #calls = 0;
  #raw;
  constructor() { completeConstructed++; }
  async init(ext) { await Promise.resolve(); this.#raw = ext; }
  async homeContent(filter) { return {raw:this.#raw,filter,calls:++this.#calls}; }
  homeVideoContent = () => ({raw:this.#raw,calls:++this.#calls});
  categoryContent(tid,pg,filter,extend) { return {tid,pg,filter,extend,calls:++this.#calls}; }
  searchContent(wd,quick,pg) { return {wd,quick,pg,calls:++this.#calls}; }
  detailContent(ids) { return {ids,calls:++this.#calls}; }
  playerContent(flag,id,vip) { return {flag,id,vip,raw:this.#raw,calls:++this.#calls}; }
}
globalThis.completeRaw = ' \n { "title" : "本机配置" } \t';
globalThis.completeSpider = __movieSelectSpider({default:CompleteSpider},{rawExtension:completeRaw});
)JS"],JS_EVAL_TYPE_MODULE,@"complete-spider-module.js");
    while(jsExecutePendingJob(rt)>0){}
    spiderOperation(ctx,rt,@"completeSpider.init({normalized:'must not replace raw ext'})",@"completeInit");
    spiderOperation(ctx,rt,@"completeSpider.home(true)",@"completeHome");
    spiderOperation(ctx,rt,@"completeSpider.homeVod()",@"completeHomeVod");
    [checks addObject:@{@"name":@"quickjs_complete_spider_class_raw_ext_state",@"passed":@(boolean(ctx,@"completeConstructed===1&&JSON.parse(completeHome).raw===completeRaw&&JSON.parse(completeHome).filter===true&&JSON.parse(completeHome).calls===1&&JSON.parse(completeHomeVod).raw===completeRaw&&JSON.parse(completeHomeVod).calls===2"))}];
    spiderOperation(ctx,rt,@"completeSpider.category('movie',2,true,{type:'dzp'})",@"completeCategory");
    spiderOperation(ctx,rt,@"completeSpider.search('keyword',false,3)",@"completeSearch");
    [checks addObject:@{@"name":@"quickjs_complete_spider_string_pages",@"passed":@(boolean(ctx,@"JSON.stringify(JSON.parse(completeCategory))===JSON.stringify({tid:'movie',pg:'2',filter:true,extend:{type:'dzp'},calls:3})&&JSON.stringify(JSON.parse(completeSearch))===JSON.stringify({wd:'keyword',quick:false,pg:'3',calls:4})"))}];
    spiderOperation(ctx,rt,@"completeSpider.detail('42')",@"completeDetail");
    spiderOperation(ctx,rt,@"completeSpider.detail(['43','44'])",@"completeDetailArray");
    spiderOperation(ctx,rt,@"completeSpider.play('line','42',['vip'])",@"completePlayer");
    [checks addObject:@{@"name":@"quickjs_complete_spider_detail_array_player_state",@"passed":@(boolean(ctx,@"JSON.stringify(JSON.parse(completeDetail))===JSON.stringify({ids:['42'],calls:5})&&JSON.stringify(JSON.parse(completeDetailArray))===JSON.stringify({ids:['43','44'],calls:6})&&JSON.stringify(JSON.parse(completePlayer))===JSON.stringify({flag:'line',id:'42',vip:['vip'],raw:completeRaw,calls:7})&&completeConstructed===1"))}];
    jsSetOperationTimeout(rt,8000);
    evaluate(ctx,[NSString stringWithUTF8String:R"JS(
globalThis.shortSpider = __movieSelectSpider({
  init(ext) { this.ext = ext; },
  home(filter) { return {short:'home',ext:this.ext,filter}; },
  homeContent() { throw Error('full home overrode short'); },
  homeVideoContent() { return {ext:this.ext}; },
  category(tid,pg) { return {short:'category',pg}; },
  categoryContent() { throw Error('full category overrode short'); },
  search(wd,quick,pg) { return {short:'search',pg}; },
  searchContent() { throw Error('full search overrode short'); },
  detail(id) { return {short:'detail',id}; },
  detailContent() { throw Error('full detail overrode short'); },
  play(flag,id,vip) { return {short:'play',flag,id,vip}; },
  playerContent() { throw Error('full play overrode short'); }
},{rawExtension:'must not replace legacy object'});
)JS"],JS_EVAL_TYPE_GLOBAL,@"short-spider-fixture.js");
    spiderOperation(ctx,rt,@"shortSpider.init({legacy:true})",@"shortInit");
    spiderOperation(ctx,rt,@"shortSpider.home(true)",@"shortHome");
    spiderOperation(ctx,rt,@"shortSpider.homeVod()",@"shortHomeVod");
    spiderOperation(ctx,rt,@"shortSpider.category('movie',2,true,{})",@"shortCategory");
    spiderOperation(ctx,rt,@"shortSpider.search('keyword',false,3)",@"shortSearch");
    spiderOperation(ctx,rt,@"shortSpider.detail('42')",@"shortDetail");
    spiderOperation(ctx,rt,@"shortSpider.play('line','42',[])",@"shortPlayer");
    [checks addObject:@{@"name":@"quickjs_complete_spider_short_names_keep_legacy_contract",@"passed":@(boolean(ctx,@"JSON.stringify(JSON.parse(shortHome))===JSON.stringify({short:'home',ext:{legacy:true},filter:true})&&JSON.parse(shortHomeVod).ext.legacy===true&&JSON.stringify(JSON.parse(shortCategory))===JSON.stringify({short:'category',pg:2})&&JSON.stringify(JSON.parse(shortSearch))===JSON.stringify({short:'search',pg:3})&&JSON.stringify(JSON.parse(shortDetail))===JSON.stringify({short:'detail',id:'42'})&&JSON.stringify(JSON.parse(shortPlayer))===JSON.stringify({short:'play',flag:'line',id:'42',vip:[]})"))}];
  } @catch(NSException *error) {
    [checks addObject:@{@"name":error.reason?:@"quickjs_exception",@"passed":@NO}];
    return checks;
  } @finally {jsFreeContext(ctx);jsFreeRuntime(rt);}
  // A new source owns a fresh production QuickJS VM. Keep all prior Python and
  // Spider checks unchanged; this profile imports the original shipped modules.
  rt=jsNewRuntime(channel,10000);ctx=jsNewContext(rt);
  JS_SetMaxStackSize(rt,512*1024);JS_SetMemoryLimit(rt,48*1024*1024);
  @try {
    NSArray *groupNames=@[@"quickjs_catvod_class_lifecycle",@"quickjs_catvod_query_unicode",
      @"quickjs_catvod_json_form",@"quickjs_catvod_raw_request_bytes",@"quickjs_catvod_response_buffer_types",
      @"quickjs_catvod_error_contract",@"quickjs_catvod_local_proxy",@"quickjs_catvod_page_crypto"];
    NSString *interop=[NSString stringWithContentsOfFile:[assets stringByAppendingPathComponent:@"js-host/module-interop.js"] encoding:NSUTF8StringEncoding error:nil];
    NSString *crypto=[NSString stringWithContentsOfFile:[assets stringByAppendingPathComponent:@"js-host/crypto-js.js"] encoding:NSUTF8StringEncoding error:nil];
    NSString *catvod=[NSString stringWithContentsOfFile:[assets stringByAppendingPathComponent:@"js-host/catvod.mjs"] encoding:NSUTF8StringEncoding error:nil];
    NSString *bridge=[NSString stringWithContentsOfFile:[assets stringByAppendingPathComponent:@"catvod_native_bridge.js"] encoding:NSUTF8StringEncoding error:nil];
    NSString *fixture=[NSString stringWithContentsOfFile:[assets stringByAppendingPathComponent:@"catvod_native_fixture.mjs"] encoding:NSUTF8StringEncoding error:nil];
    if(!interop||!crypto||!catvod||!bridge||!fixture)
      @throw [NSException exceptionWithName:@"QuickJsProbe" reason:@"catvod_native_asset_missing" userInfo:nil];
    jsSetOperationTimeout(rt,8000);
    evaluate(ctx,@"globalThis.console={log(){},warn(){},error(){}};");
    evaluate(ctx,interop,JS_EVAL_TYPE_GLOBAL,@"module-interop.js");
    // The bridge returns owned synthetic response bytes. It does not exercise
    // Dart sockets or claim HTTP transport acceptance on this platform.
    evaluate(ctx,bridge,JS_EVAL_TYPE_GLOBAL,@"catvod_native_bridge.js");
    NSString *cryptoModule=[@"const module={exports:{}};let exports=module.exports;\n" stringByAppendingFormat:@"%@\nexport default module.exports;",crypto];
    jsSetOperationTimeout(rt,8000);
    evaluate(ctx,cryptoModule,JS_EVAL_TYPE_MODULE,@"marco:catvod-crypto");
    while(jsExecutePendingJob(rt)>0){}
    jsSetOperationTimeout(rt,8000);
    evaluate(ctx,catvod,JS_EVAL_TYPE_MODULE,@"catvod");
    while(jsExecutePendingJob(rt)>0){}
    jsSetOperationTimeout(rt,8000);
    evaluate(ctx,fixture,JS_EVAL_TYPE_MODULE,@"catvod_native_fixture.mjs");
    while(jsExecutePendingJob(rt)>0){}
    if(!boolean(ctx,[NSString stringWithFormat:@"JSON.stringify(__catvodNativeGroupNames)===JSON.stringify(%@)",literal(groupNames)]))
      @throw [NSException exceptionWithName:@"QuickJsProbe" reason:@"catvod_native_group_inventory" userInfo:nil];
    for(NSUInteger index=0;index<groupNames.count;index++) {
      // spiderOperation resets the original eight-second operation budget.
      spiderOperation(ctx,rt,[NSString stringWithFormat:@"__catvodRunNativeGroup(%lu)",(unsigned long)index],@"catvodNativeResult");
      BOOL passed=boolean(ctx,[NSString stringWithFormat:@"(()=>{const r=JSON.parse(catvodNativeResult);return r.name===%@&&r.passed===true&&Number.isInteger(r.assertions)&&r.assertions>0;})()",literal(groupNames[index])]);
      NSMutableDictionary *check=[@{@"name":groupNames[index],@"passed":@(passed),@"transport_scope":@"synthetic bridge; no socket claim"} mutableCopy];
      if(!passed) check[@"diagnostic"]=diagnostic(ctx,@"catvodNativeResult");
      [checks addObject:check];
    }
  } @catch(NSException *error) {
    [checks addObject:@{@"name":error.reason?:@"catvod_quickjs_exception",@"passed":@NO}];
    return checks;
  } @finally {jsFreeContext(ctx);jsFreeRuntime(rt);}
  rt=jsNewRuntime(channel,100);ctx=jsNewContext(rt);
  @try {
    evaluate(ctx,@"globalThis.retainedCounter=1;");
    [NSThread sleepForTimeInterval:.15];
    jsSetOperationTimeout(rt,1000);
    evaluate(ctx,@"retainedCounter++;");
    [checks addObject:@{@"name":@"quickjs_native_renewed_operation_deadline",@"passed":@(boolean(ctx,@"retainedCounter===2"))}];
    jsSetOperationTimeout(rt,100);
    const char *loop="while(true){}";
    JSValue *value=jsEval(ctx,loop,strlen(loop),"deadline.js",JS_EVAL_TYPE_GLOBAL);
    [checks addObject:@{@"name":@"quickjs_native_deadline",@"passed":@(JS_IsException(*value))}];
    jsFreeValue(ctx,value,1);
    JSValue error=JS_GetException(ctx);JS_FreeValue(ctx,error);
  } @finally {jsFreeContext(ctx);jsFreeRuntime(rt);}
  return checks;
}
