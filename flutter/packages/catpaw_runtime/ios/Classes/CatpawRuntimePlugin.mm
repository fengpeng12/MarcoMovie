// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
#import "CatpawRuntimePlugin.h"
#import "CatpawRuntimeEngine.h"

@implementation CatpawRuntimePlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *channel = [FlutterMethodChannel methodChannelWithName:@"marco_movie/catpaw"
      binaryMessenger:[registrar messenger]];
  [registrar addMethodCallDelegate:[[CatpawRuntimePlugin alloc] init] channel:channel];
}
- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  if (![call.method isEqualToString:@"start"]) { result(FlutterMethodNotImplemented); return; }
  NSDictionary *args = [call.arguments isKindOfClass:[NSDictionary class]] ? call.arguments : nil;
  NSError *error = nil;
  if (![CatpawRuntimeEngine startWithRoot:args[@"root"] script:args[@"script"]
                                  ready:args[@"ready"] error:&error]) {
    NSString *code = error.localizedDescription;
    result([FlutterError errorWithCode:code
      message:[code isEqualToString:@"invalid_path"] ? @"CatPaw 路径无效" : @"请重新打开应用以启动 CatPaw"
      details:nil]);
    return;
  }
  result(nil);
}
@end
