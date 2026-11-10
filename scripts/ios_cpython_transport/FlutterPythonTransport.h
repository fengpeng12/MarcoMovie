// Owned-fixture-only transport. No product registration or user script entry.
#import <Flutter/Flutter.h>
#import <Python/Python.h>

@interface FlutterPythonTransport : NSObject
- (instancetype)initWithChannel:(FlutterMethodChannel *)channel;
- (BOOL)beginOrigins:(NSArray<NSString *> *)origins;
- (void)endProbe;
- (NSUInteger)cancelCall:(NSString *)callId;
@end

// Invoke only while the current subinterpreter's thread state is attached.
// The returned callable belongs to that interpreter; never share it with another.
PyObject *MMCreateFixtureTransportBridge(FlutterPythonTransport *transport);
