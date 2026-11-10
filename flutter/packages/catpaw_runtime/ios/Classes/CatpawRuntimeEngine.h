// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>

/// One embedded Node instance for the application lifetime. Source workers can
/// be reset without restarting Node or terminating the iOS process.
@interface CatpawRuntimeEngine : NSObject
+ (BOOL)startWithRoot:(NSString *)root script:(NSString *)script
               ready:(NSString *)ready error:(NSError **)error;
@end
