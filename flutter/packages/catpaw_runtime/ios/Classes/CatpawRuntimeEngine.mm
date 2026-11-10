// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
#import "CatpawRuntimeEngine.h"
#import <NodeMobile/NodeMobile.h>
#include <vector>
#include <cstring>

@implementation CatpawRuntimeEngine
static BOOL started = NO;
static BOOL exited = NO;
static NSString *runtimeRoot;

+ (BOOL)startWithRoot:(NSString *)root script:(NSString *)script
               ready:(NSString *)ready error:(NSError **)error {
  NSString *failure = nil;
  if (![root isKindOfClass:[NSString class]] || !root.isAbsolutePath ||
      ![script isKindOfClass:[NSString class]] || ![ready isKindOfClass:[NSString class]] ||
      ![script isEqualToString:[root stringByAppendingPathComponent:@"host.cjs"]] ||
      ![ready isEqualToString:[root stringByAppendingPathComponent:@"ready.json"]]) {
    failure = @"invalid_path";
  } else {
    @synchronized(self) {
      if (exited || (started && ![runtimeRoot isEqualToString:root])) {
        failure = @"restart_required";
      } else if (!started) {
        [[NSFileManager defaultManager] removeItemAtPath:ready error:nil];
        runtimeRoot = [root copy]; started = YES;
        NSArray<NSString *> *arguments = @[@"node", @"--jitless", script, root, ready, @"--embedded"];
        NSThread *thread = [[NSThread alloc] initWithBlock:^{
          @autoreleasepool {
            size_t size = 0;
            for (NSString *argument in arguments) size += strlen(argument.UTF8String) + 1;
            std::vector<char> buffer(size);
            std::vector<char *> argv(arguments.count + 1, nullptr);
            char *cursor = buffer.data();
            for (NSUInteger i = 0; i < arguments.count; i++) {
              argv[i] = cursor;
              size_t count = strlen(arguments[i].UTF8String) + 1;
              memcpy(cursor, arguments[i].UTF8String, count); cursor += count;
            }
            node_start((int)arguments.count, argv.data());
            @synchronized(self) { exited = YES; }
          }
        }];
        thread.stackSize = 8 * 1024 * 1024;
        thread.name = @"catpaw-node";
        [thread start];
      }
    }
  }
  if (failure && error) {
    *error = [NSError errorWithDomain:@"marco_movie.catpaw" code:1
      userInfo:@{NSLocalizedDescriptionKey:failure}];
  }
  return failure == nil;
}
@end
