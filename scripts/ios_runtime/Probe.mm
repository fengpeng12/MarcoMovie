// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// A simulator-only app that links the production engine and runs production JS.
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#import "CatpawRuntimeEngine.h"
#import "LoopbackDiagnostics.h"
extern NSArray *runQuickJsProbe(NSString *assets);

static NSMutableArray *checks;
static void check(BOOL ok, NSString *name) {
  [checks addObject:@{@"name":name,@"passed":@(ok)}];
  if (!ok) @throw [NSException exceptionWithName:@"ProbeFailure" reason:name userInfo:nil];
}
static NSData *jsonData(id value) {
  return [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
}
static id json(NSData *value) {
  return [NSJSONSerialization JSONObjectWithData:value options:NSJSONReadingFragmentsAllowed error:nil];
}
static NSData *request(NSString *address, NSString *method, id body, NSDictionary *headers) {
  NSMutableURLRequest *req=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:address]];
  req.HTTPMethod=method; req.timeoutInterval=25;
  if (body) { req.HTTPBody=jsonData(body); [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"]; }
  for (NSString *key in headers) [req setValue:headers[key] forHTTPHeaderField:key];
  dispatch_semaphore_t done=dispatch_semaphore_create(0);
  __block NSData *bytes=nil; __block NSError *failure=nil; __block NSInteger status=0;
  NSURLSession *session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
  [[session dataTaskWithRequest:req completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){
    bytes=data;failure=error;status=((NSHTTPURLResponse *)response).statusCode;
    dispatch_semaphore_signal(done);
  }] resume];
  long timedOut=dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC));
  [session invalidateAndCancel];
  if (timedOut||failure||status<200||status>=300)
    @throw [NSException exceptionWithName:@"TransportFailure"
      reason:[NSString stringWithFormat:@"local HTTP status=%ld error=%ld timeout=%ld",(long)status,(long)failure.code,timedOut]
      userInfo:nil];
  return bytes;
}
static NSString *install(NSString *root,NSString *name,NSData *data) {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
  NSMutableString *key=[NSMutableString string];
  for(int i=0;i<CC_SHA256_DIGEST_LENGTH;i++)[key appendFormat:@"%02x",digest[i]];
  NSString *folder=[root stringByAppendingPathComponent:key];
  [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
  [data writeToFile:[folder stringByAppendingPathComponent:name] atomically:YES];
  return key;
}
static id call(NSString *base,NSString *key,NSString *method,NSArray *args) {
  return json(request([NSString stringWithFormat:@"%@/%@/api/drpy",base,key],@"POST",
    @{@"version":@1,@"method":method,@"args":args},@{}));
}

@interface ProbeDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation ProbeDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
  self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  UIViewController *view=[UIViewController new];view.view.backgroundColor=UIColor.blackColor;
  self.window.rootViewController=view;[self.window makeKeyAndVisible];
  NSThread *probe=[[NSThread alloc] initWithBlock:^{ @autoreleasepool { [self runProbe]; } }];
  probe.stackSize=8*1024*1024;probe.name=@"source-runtime-probe";[probe start];
  return YES;
}
- (void)runProbe {
  checks=[NSMutableArray array];NSString *failure=nil;NSString *runtimeVersion=@"";
  NSMutableDictionary *transportDiagnostics=[NSMutableDictionary dictionary];
  @try {
    NSArray *quickChecks=runQuickJsProbe(NSBundle.mainBundle.resourcePath);
    [checks addObjectsFromArray:quickChecks];
    for(NSDictionary *result in quickChecks)
      if(![result[@"passed"] boolValue]) @throw [NSException exceptionWithName:@"ProbeFailure" reason:result[@"name"] userInfo:nil];
    NSFileManager *fm=NSFileManager.defaultManager;
    NSString *root=[[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES) firstObject]
      stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *assets=[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"runtime"];
    for(NSString *name in [fm contentsOfDirectoryAtPath:assets error:nil])
      [fm copyItemAtPath:[assets stringByAppendingPathComponent:name] toPath:[root stringByAppendingPathComponent:name] error:nil];
    NSString *script=[root stringByAppendingPathComponent:@"host.cjs"],*ready=[root stringByAppendingPathComponent:@"ready.json"];
    NSError *error=nil;
    check([CatpawRuntimeEngine startWithRoot:root script:script ready:ready error:&error],@"production_engine_start");
    NSDictionary *state=nil;NSDate *until=[NSDate dateWithTimeIntervalSinceNow:15];
    while([until timeIntervalSinceNow]>0){
      NSData *data=[NSData dataWithContentsOfFile:ready];
      if(data){state=json(data);if(state[@"port"]&&state[@"secret"])break;}
      [NSThread sleepForTimeInterval:.04];
    }
    check(state[@"port"]!=nil,@"embedded_node_ready");
    NSString *base=[NSString stringWithFormat:@"http://127.0.0.1:%@/%@",state[@"port"],state[@"secret"]];
    transportDiagnostics[@"raw_socket_health"]=loopbackHealthDiagnostic([base stringByAppendingString:@"/health"]);
    NSDictionary *health=json(request([base stringByAppendingString:@"/health"],@"GET",nil,@{}));
    runtimeVersion=health[@"runtime"]?:@"";
    check([runtimeVersion hasPrefix:@"18.20.4"],@"actual_node_18_runtime");
    NSString *fixture=[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"fixture.cjs"];
    NSString *cat=install(root,@"index.cjs",[NSData dataWithContentsOfFile:fixture]);
    NSString *catBase=[NSString stringWithFormat:@"%@/%@",base,cat];
    NSDictionary *catalog=json(request([catBase stringByAppendingString:@"/t4"],@"GET",nil,@{}));
    check([catalog[@"sites"] count]==1&&[catalog[@"starts"] intValue]==1,@"catpaw_worker_catalog");
    NSData *fetched=request([catBase stringByAppendingString:@"/api/fetch"],@"GET",nil,@{});
    const unsigned char expected[]={0,1,255,42};
    check([fetched isEqualToData:[NSData dataWithBytes:expected length:4]],@"jitless_fetch_binary");
    NSDictionary *signedPlay=json(request([catBase stringByAppendingString:@"/api/play"],@"GET",nil,@{}));
    NSString *signedPlaylist=[[NSString alloc] initWithData:request(signedPlay[@"url"],@"GET",nil,@{}) encoding:NSUTF8StringEncoding];
    NSString *signedKey=[catBase stringByAppendingString:@"/spider/demo/3/proxy/token/key?sig=fixture"];
    check([signedPlaylist hasPrefix:@"#EXTM3U"]&&[signedPlaylist containsString:signedKey],@"catpaw_signed_hls_proxy");
    check([request(signedKey,@"GET",nil,@{}) isEqualToData:[NSData dataWithBytes:expected length:4]],@"catpaw_signed_proxy_key");
    NSDictionary *ruleData=@{@"title":@"iOS fixture",@"host":@"https://fixture.invalid",
      @"class_name":@"电影",@"class_url":@"films",@"url":@"/category/fyclass",@"searchUrl":@"/search?wd=**",@"searchable":@2,
      @"预处理":@"js:require(\"./helpers/entry.js\");",
      @"一级":@"js:VODS=[{vod_id:\"one\",vod_name:fixtureTitle}];",
      @"搜索":@"js:VODS=[{vod_id:\"one\",vod_name:fixtureTitle}];",
      @"二级":@"js:VOD={vod_name:fixtureTitle,vod_play_from:\"demo\",vod_play_url:\"第一集$one\"};",
      @"play_parse":@YES,@"lazy":@"js:input={parse:0,url:getProxyUrl()+\"&kind=playlist\"};",
      @"proxy_rule":@"js:input=input.kind===\"key\"?[200,\"application/octet-stream\",[0,1,255,42]]:[200,\"application/vnd.apple.mpegurl\",\"#EXTM3U\\n#EXT-X-VERSION:3\\n\"];"};
    NSString *rule=[NSString stringWithFormat:@"var rule=%@;",[[NSString alloc] initWithData:jsonData(ruleData) encoding:NSUTF8StringEncoding]];
    NSDictionary *manifest=@{@"kind":@"drpy",@"version":@1,@"runtime":@"drpy2-ca23ffdb-1",
      @"sourceId":[@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0],
      @"origin":@"pkg://archive/main.js",@"rule":rule,@"headers":@{},@"requestTimeoutMs":@1000,
      @"modules":@{@"pkg://archive/helpers/entry.js":@"require('./nested/title.js');",
        @"pkg://archive/helpers/nested/title.js":@"globalThis.fixtureTitle='iOS 本机影片';"}};
    NSString *drpy=install(root,@"drpy.json",jsonData(manifest));
    NSDictionary *home=call(base,drpy,@"home",@[@YES]);
    check([home[@"class"] count]==1,@"drpy_home");
    NSDictionary *category=call(base,drpy,@"category",@[@"films",@1,@NO,@{}]);
    check([category[@"list"][0][@"vod_name"] isEqual:@"iOS 本机影片"],@"drpy_local_nested_modules");
    NSDictionary *search=call(base,drpy,@"search",@[@"本机",@NO,@1]);
    check([search[@"list"] count]==1,@"drpy_search");
    NSDictionary *detail=call(base,drpy,@"detail",@[@"one"]);
    check([detail[@"list"][0][@"vod_play_url"] length]>0,@"drpy_detail_episodes");
    NSDictionary *play=call(base,drpy,@"play",@[@"demo",@"one",@[]]);
    NSString *playlist=play[@"url"];
    NSString *text=[[NSString alloc] initWithData:request(playlist,@"GET",nil,@{}) encoding:NSUTF8StringEncoding];
    check([text hasPrefix:@"#EXTM3U"],@"drpy_local_proxy_playlist");
    NSString *keyURL=[playlist stringByReplacingOccurrencesOfString:@"kind=playlist" withString:@"kind=key"];
    NSData *range=request(keyURL,@"GET",nil,@{@"Range":@"bytes=1-2"});
    check([range isEqualToData:[NSData dataWithBytes:expected+1 length:2]],@"drpy_proxy_binary_range");
    NSString *t4Rule=[NSString stringWithContentsOfFile:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"t4-rule.js"] encoding:NSUTF8StringEncoding error:nil];
    t4Rule=[t4Rule stringByReplacingOccurrencesOfString:@"http://fixture.invalid/api/cms" withString:[catBase stringByAppendingString:@"/api/cms"]];
    NSURLComponents *local=[NSURLComponents componentsWithString:catBase];
    NSString *localOrigin=[NSString stringWithFormat:@"%@://%@:%@",local.scheme,local.host,local.port];
    t4Rule=[t4Rule stringByReplacingOccurrencesOfString:@"http://fixture.invalid" withString:localOrigin];
    NSString *t4=install(root,@"drpy.json",jsonData(@{@"kind":@"drpy",@"version":@1,@"runtime":@"drpy2-ca23ffdb-1",
      @"sourceId":[@"b" stringByPaddingToLength:64 withString:@"b" startingAtIndex:0],@"origin":[catBase stringByAppendingString:@"/api/cms"],
      @"rule":t4Rule,@"headers":@{},@"requestTimeoutMs":@2000}));
    NSDictionary *t4Home=call(base,t4,@"home",@[@YES]);
    check([t4Home[@"class"] count]==1&&[t4Home[@"list"][0][@"vod_name"] isEqual:@"T4 本机影片"],@"t4_native_catalog");
    NSDictionary *t4Category=call(base,t4,@"category",@[@"1",@2,@NO,@{}]);
    check([t4Category[@"page"] intValue]==2&&[t4Category[@"pagecount"] intValue]==3,@"t4_native_pagination");
    NSDictionary *t4Detail=call(base,t4,@"detail",@[@"opaque/$#?"]);
    check([t4Detail[@"list"][0][@"vod_id"] isEqual:@"opaque/$#?"],@"t4_native_opaque_detail_id");
    NSString *t4Media=[t4Detail[@"list"][0][@"vod_play_url"] componentsSeparatedByString:@"$"][1];
    NSDictionary *t4Play=call(base,t4,@"play",@[@"one",t4Media,@[]]);
    NSString *t4Playlist=[[NSString alloc] initWithData:request(t4Play[@"url"],@"GET",nil,@{}) encoding:NSUTF8StringEncoding];
    check([t4Playlist hasPrefix:@"#EXTM3U"],@"t4_native_play_manifest");
    NSString *fyOrigin=[[NSString alloc] initWithData:[[NSData alloc] initWithBase64EncodedString:catalog[@"fyOrigin"] options:0] encoding:NSUTF8StringEncoding];
    NSString *fyRule=[NSString stringWithContentsOfFile:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"fy-rule.js"] encoding:NSUTF8StringEncoding error:nil];
    fyRule=[fyRule stringByReplacingOccurrencesOfString:@"http://fixture.invalid" withString:fyOrigin];
    NSString *fy=install(root,@"drpy.json",jsonData(@{@"kind":@"drpy",@"version":@1,@"runtime":@"drpy2-ca23ffdb-1",
      @"sourceId":[@"c" stringByPaddingToLength:64 withString:@"c" startingAtIndex:0],@"origin":fyOrigin,
      @"rule":fyRule,@"headers":@{},@"requestTimeoutMs":@2000}));
    NSDictionary *fyHome=call(base,fy,@"home",@[@YES]);
    check([fyHome[@"class"] count]==8&&[fyHome[@"filters"][@"1"] count]==7,@"fy_native_categories_filters");
    NSDictionary *image=call(base,fy,@"action",@[@"{\"type\":\"verification\",\"operation\":\"challenge\"}"]);
    NSData *imageBytes=[[NSData alloc] initWithBase64EncodedString:image[@"imageBase64"] options:0];
    check([image[@"mime"] isEqual:@"image/png"]&&imageBytes.length>8,@"fy_native_image_challenge");
    NSMutableDictionary *submission=[@{@"type":@"verification",@"operation":@"submit",@"id":image[@"id"],@"code":@"NOPE"} mutableCopy];
    NSString *action=[[NSString alloc] initWithData:jsonData(submission) encoding:NSUTF8StringEncoding];
    check(![call(base,fy,@"action",@[action])[@"verified"] boolValue],@"fy_native_verification_rejected");
    submission[@"code"]=@"AB12";action=[[NSString alloc] initWithData:jsonData(submission) encoding:NSUTF8StringEncoding];
    check([call(base,fy,@"action",@[action])[@"verified"] boolValue],@"fy_native_verification_session");
    check([call(base,fy,@"homeVod",@[])[@"list"][0][@"vod_name"] isEqual:@"FY 本机影片"],@"fy_native_catalog");
    NSDictionary *fyCategory=call(base,fy,@"category",@[@"1",@2,@YES,@{@"area":@"美国",@"year":@"2026"}]);
    check([fyCategory[@"page"] intValue]==2&&[fyCategory[@"pagecount"] intValue]==4,@"fy_native_pagination");
    NSDictionary *fyDetail=call(base,fy,@"detail",@[@"123"]);
    check([fyDetail[@"list"][0][@"vod_play_url"] isEqual:@"第一集$123-1-1#第二集$123-1-2"],@"fy_native_episode_order");
    NSDictionary *fyPlay=call(base,fy,@"play",@[@"线路 A",@"123-1-1",@[]]);
    NSString *fyPlaylist=[[NSString alloc] initWithData:request(fyPlay[@"url"],@"GET",nil,@{}) encoding:NSUTF8StringEncoding];
    check([fyPlaylist hasPrefix:@"#EXTM3U"],@"fy_native_parser_session_manifest");
    request([NSString stringWithFormat:@"%@/%@/_release",base,fy],@"POST",nil,@{});
    check([call(base,fy,@"homeVod",@[])[@"list"] count]==1,@"fy_native_verified_session_reopen");
    NSDictionary *reset=json(request([base stringByAppendingString:@"/_reset"],@"POST",@{},@{}));
    check([reset[@"reset"] boolValue],@"embedded_reset_without_process_exit");
    check([CatpawRuntimeEngine startWithRoot:root script:script ready:ready error:&error],@"native_reopen_same_root");
    catalog=json(request([catBase stringByAppendingString:@"/t4"],@"GET",nil,@{}));
    check([catalog[@"starts"] intValue]==2,@"catpaw_worker_recreated_with_saved_state");
    home=call(base,drpy,@"home",@[@YES]);
    check([home[@"class"] count]==1,@"drpy_reopen");
  } @catch(NSException *error) { failure=error.reason?:@"probe_exception"; }
  NSDictionary *report=@{@"passed":@(failure==nil),@"checks":checks,@"failure":failure?:@"",
    @"transport_diagnostics":transportDiagnostics,
    @"runtime":runtimeVersion,@"scope":@"iOS simulator, production Node engine and scripts; no Flutter UI or media decoder acceptance"};
  NSString *folder=[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES) firstObject];
  [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
  [jsonData(report) writeToFile:[folder stringByAppendingPathComponent:@"result.json"] atomically:YES];
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(ProbeDelegate.class));}}
