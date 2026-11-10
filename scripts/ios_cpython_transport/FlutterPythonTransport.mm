// Experimental Python -> asynchronous Dart MethodChannel transport.
#import "FlutterPythonTransport.h"
#include <math.h>

static const NSUInteger MMBodyLimit = 6 * 1024 * 1024;

@interface MMTransportPending : NSObject
@property(nonatomic,copy) NSString *callId;
@property(nonatomic,copy) NSString *requestId;
@property(nonatomic,strong) dispatch_semaphore_t signal;
@property(nonatomic,strong) id response;
@property(nonatomic,copy) NSString *error;
@property(nonatomic,assign) BOOL settled;
@end
@implementation MMTransportPending
@end

@interface FlutterPythonTransport ()
@property(nonatomic,strong) FlutterMethodChannel *channel;
@property(nonatomic,strong) NSLock *lock;
@property(nonatomic,strong) NSMutableDictionary<NSString *,MMTransportPending *> *pending;
@property(nonatomic,strong) NSMutableSet<NSString *> *cancelled;
@property(nonatomic,copy) NSArray<NSString *> *origins;
- (id)performRequest:(NSDictionary *)envelope error:(NSString **)error;
- (id)claimResponse:(MMTransportPending *)pending error:(NSString **)error;
@end

static BOOL MMIdentity(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] != 32) return NO;
    NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
    return [value rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

static BOOL MMPositiveInteger(id value, NSUInteger maximum) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()) return NO;
    double number=[value doubleValue];
    return isfinite(number) && number>=1 && number<=maximum && floor(number)==number;
}

@implementation FlutterPythonTransport
- (instancetype)initWithChannel:(FlutterMethodChannel *)channel {
    if ((self=[super init])) {
        _channel=channel;_lock=[NSLock new];_pending=[NSMutableDictionary dictionary];_cancelled=[NSMutableSet set];
    }
    return self;
}
- (BOOL)beginOrigins:(NSArray<NSString *> *)origins {
    [self.lock lock];
    BOOL available=self.origins==nil && self.pending.count==0;
    if (available) { self.origins=[origins copy];[self.cancelled removeAllObjects]; }
    [self.lock unlock];return available;
}
- (void)dispatchCancel:(NSString *)callId {
    dispatch_async(dispatch_get_main_queue(),^{
        [self.channel invokeMethod:@"transport.cancel" arguments:@{@"version":@1,@"callId":callId}];
    });
}
- (BOOL)settle:(MMTransportPending *)pending response:(id)response error:(NSString *)error {
    [self.lock lock];
    BOOL owned=self.pending[pending.requestId]==pending && !pending.settled;
    if (owned) {
        pending.response=response;pending.error=error;pending.settled=YES;
    }
    [self.lock unlock];
    if (owned) dispatch_semaphore_signal(pending.signal);
    return owned;
}
- (NSUInteger)cancelCall:(NSString *)callId {
    [self.lock lock];
    if (self.origins && self.cancelled.count<64) [self.cancelled addObject:callId];
    NSArray *values=self.pending.allValues;
    NSMutableArray *cancelled=[NSMutableArray array];
    NSUInteger count=0;
    for (MMTransportPending *pending in values) {
        if (![pending.callId isEqualToString:callId]) continue;
        count++;pending.error=@"cancelled";pending.response=nil;
        if (!pending.settled) { pending.settled=YES;[cancelled addObject:pending]; }
    }
    [self.lock unlock];
    for (MMTransportPending *pending in cancelled) dispatch_semaphore_signal(pending.signal);
    [self dispatchCancel:callId];
    return count;
}
- (void)endProbe {
    [self.lock lock];NSArray *values=self.pending.allValues;self.origins=nil;
    NSMutableArray *wake=[NSMutableArray array];
    for (MMTransportPending *pending in values) {
        pending.error=@"cancelled";pending.response=nil;
        if (!pending.settled) { pending.settled=YES;[wake addObject:pending]; }
    }
    [self.pending removeAllObjects];[self.cancelled removeAllObjects];[self.lock unlock];
    for (MMTransportPending *pending in wake) dispatch_semaphore_signal(pending.signal);
    for (MMTransportPending *pending in values) [self dispatchCancel:pending.callId];
}
- (id)performRequest:(NSDictionary *)envelope error:(NSString **)error {
    if ([NSThread isMainThread]) { *error=@"protocol";return nil; }
    NSSet *keys=[NSSet setWithArray:@[@"version",@"callId",@"requestId",@"url",@"method",@"headers",@"body",@"connectTimeoutMs",@"readTimeoutMs",@"deadlineRemainingMs"]];
    if (![envelope isKindOfClass:NSDictionary.class] || ![[NSSet setWithArray:envelope.allKeys] isEqualToSet:keys]
            || !MMPositiveInteger(envelope[@"version"],1) || !MMIdentity(envelope[@"callId"]) || !MMIdentity(envelope[@"requestId"])
            || !MMPositiveInteger(envelope[@"connectTimeoutMs"],45000) || !MMPositiveInteger(envelope[@"readTimeoutMs"],45000)
            || !MMPositiveInteger(envelope[@"deadlineRemainingMs"],45000) || ![envelope[@"body"] isKindOfClass:NSData.class]
            || [envelope[@"body"] length]>MMBodyLimit || ![envelope[@"headers"] isKindOfClass:NSArray.class]
            || [envelope[@"headers"] count]>128 || ![@[@"GET",@"HEAD",@"POST",@"PUT",@"PATCH",@"DELETE",@"OPTIONS"] containsObject:envelope[@"method"]]) {
        *error=@"protocol";return nil;
    }
    NSString *address=[envelope[@"url"] isKindOfClass:NSString.class]?envelope[@"url"]:nil;
    NSURLComponents *url=address?[NSURLComponents componentsWithString:address]:nil;
    if (!url || ![url.scheme isEqualToString:@"http"] || ![url.host isEqualToString:@"127.0.0.1"] || url.user || url.password || url.fragment) {
        *error=@"protocol";return nil;
    }
    for (NSString *part in [url.path componentsSeparatedByString:@"/"]) {
        if ([part isEqual:@"."] || [part isEqual:@".."] || [part containsString:@"\\"]
                || [part rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound) {
            *error=@"protocol";return nil;
        }
    }
    [self.lock lock];BOOL allowed=NO;
    for (NSString *origin in self.origins) {
        if ([address hasPrefix:[origin stringByAppendingString:@"/"]]) { allowed=YES;break; }
    }
    BOOL cancelled=[self.cancelled containsObject:envelope[@"callId"]];
    if (!allowed || cancelled || self.pending.count>=4 || self.pending[envelope[@"requestId"]]) {
        [self.lock unlock];*error=cancelled?@"cancelled":@"protocol";return nil;
    }
    MMTransportPending *pending=[MMTransportPending new];pending.callId=envelope[@"callId"];pending.requestId=envelope[@"requestId"];
    pending.signal=dispatch_semaphore_create(0);self.pending[pending.requestId]=pending;[self.lock unlock];
    NSMutableDictionary *message=[envelope mutableCopy];message[@"body"]=[FlutterStandardTypedData typedDataWithBytes:envelope[@"body"]];
    dispatch_async(dispatch_get_main_queue(),^{
        [self.lock lock];BOOL active=self.pending[pending.requestId]==pending && !pending.settled;[self.lock unlock];
        if (!active) return;
        [self.channel invokeMethod:@"transport.request" arguments:message result:^(id response) {
            // Main-thread callback touches Foundation values only. A cancelled or
            // expired request is already settled and ignores late replies. Keep
            // the record until its Python owner resumes and claims delivery.
            NSString *kind=nil;
            if ([response isKindOfClass:FlutterError.class]) {
                NSString *code=[(FlutterError *)response code];
                NSDictionary *codes=@{@"timeout":@"timeout",@"cancelled":@"cancelled",@"tls":@"tls",@"connection":@"connection",@"protocol":@"protocol"};
                kind=codes[code]?:@"protocol";
            } else if (![response isKindOfClass:NSDictionary.class]) kind=@"protocol";
            [self settle:pending response:kind?nil:response error:kind];
        }];
    });
    int64_t duration=[envelope[@"deadlineRemainingMs"] longLongValue]*NSEC_PER_MSEC;
    if (dispatch_semaphore_wait(pending.signal,dispatch_time(DISPATCH_TIME_NOW,duration))!=0) {
        [self settle:pending response:nil error:@"timeout"];
        [self dispatchCancel:pending.callId];
    }
    return pending;
}
- (id)claimResponse:(MMTransportPending *)pending error:(NSString **)error {
    // Called only on the Python owner AFTER restoring its thread state. This is
    // the linearization point: cancel before it wins, cancel after it reports no
    // pending HTTP wait and does not claim to interrupt subsequent Python work.
    [self.lock lock];
    if (self.pending[pending.requestId]!=pending || !pending.settled) {
        [self.lock unlock];*error=@"protocol";return nil;
    }
    if ([self.cancelled containsObject:pending.callId]) { pending.error=@"cancelled";pending.response=nil; }
    [self.pending removeObjectForKey:pending.requestId];
    id response=pending.response;*error=pending.error;[self.lock unlock];return response;
}
@end

static id MMFromPython(PyObject *value, NSUInteger depth) {
    if (depth>8) { PyErr_SetString(PyExc_ValueError,"Fixture request nesting exceeds limit");return nil; }
    if (value==Py_None) return NSNull.null;
    if (PyBool_Check(value)) return value==Py_True?@YES:@NO;
    if (PyLong_Check(value)) { long long number=PyLong_AsLongLong(value);return PyErr_Occurred()?nil:@(number); }
    if (PyUnicode_Check(value)) {
        Py_ssize_t length=0;const char *text=PyUnicode_AsUTF8AndSize(value,&length);
        if (!text) return nil;
        if (length>65536) { PyErr_SetString(PyExc_ValueError,"Fixture request string exceeds limit");return nil; }
        return [[NSString alloc] initWithBytes:text length:length encoding:NSUTF8StringEncoding];
    }
    if (PyBytes_Check(value)) {
        char *bytes=NULL;Py_ssize_t length=0;if (PyBytes_AsStringAndSize(value,&bytes,&length)<0) return nil;
        if (length>MMBodyLimit) { PyErr_SetString(PyExc_ValueError,"Fixture body exceeds limit");return nil; }
        return [NSData dataWithBytes:bytes length:length];
    }
    if (PyList_Check(value) || PyTuple_Check(value)) {
        Py_ssize_t count=PySequence_Size(value);
        if (count>256) { PyErr_SetString(PyExc_ValueError,"Fixture list exceeds limit");return nil; }
        NSMutableArray *array=[NSMutableArray arrayWithCapacity:count];
        for (Py_ssize_t i=0;i<count;i++) { PyObject *item=PySequence_GetItem(value,i);id converted=item?MMFromPython(item,depth+1):nil;Py_XDECREF(item);if (!converted) return nil;[array addObject:converted]; }
        return array;
    }
    if (PyDict_Check(value)) {
        if (PyDict_Size(value)>128) { PyErr_SetString(PyExc_ValueError,"Fixture dict exceeds limit");return nil; }
        NSMutableDictionary *dict=[NSMutableDictionary dictionary];Py_ssize_t pos=0;PyObject *key=NULL,*item=NULL;
        while (PyDict_Next(value,&pos,&key,&item)) {
            if (!PyUnicode_Check(key)) { PyErr_SetString(PyExc_TypeError,"Fixture keys must be strings");return nil; }
            id name=MMFromPython(key,depth+1),converted=MMFromPython(item,depth+1);if (!name || !converted) return nil;dict[name]=converted;
        }
        return dict;
    }
    PyErr_SetString(PyExc_TypeError,"Unsupported fixture request value");return nil;
}

static PyObject *MMToPython(id value, NSUInteger depth) {
    if (depth>8) { PyErr_SetString(PyExc_ValueError,"Fixture response nesting exceeds limit");return NULL; }
    if (!value || value==NSNull.null) return Py_NewRef(Py_None);
    if ([value isKindOfClass:FlutterStandardTypedData.class]) value=[(FlutterStandardTypedData *)value data];
    if ([value isKindOfClass:NSData.class]) {
        if ([value length]>MMBodyLimit) { PyErr_SetString(PyExc_ValueError,"Fixture response body exceeds limit");return NULL; }
        return PyBytes_FromStringAndSize((const char *)[value bytes],[value length]);
    }
    if ([value isKindOfClass:NSString.class]) {
        NSData *data=[value dataUsingEncoding:NSUTF8StringEncoding];
        if (!data || data.length>65536) { PyErr_SetString(PyExc_ValueError,"Fixture response string exceeds limit");return NULL; }
        return PyUnicode_DecodeUTF8((const char *)data.bytes,data.length,"strict");
    }
    if ([value isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()) return PyBool_FromLong([value boolValue]);
        double number=[value doubleValue];
        if (!isfinite(number) || floor(number)!=number) { PyErr_SetString(PyExc_ValueError,"Fixture response number must be integer");return NULL; }
        return PyLong_FromLongLong([value longLongValue]);
    }
    if ([value isKindOfClass:NSArray.class]) {
        if ([value count]>256) { PyErr_SetString(PyExc_ValueError,"Fixture response list exceeds limit");return NULL; }
        PyObject *list=PyList_New([value count]);if (!list) return NULL;
        for (NSUInteger i=0;i<[value count];i++) { PyObject *item=MMToPython(value[i],depth+1);if (!item) { Py_DECREF(list);return NULL; }PyList_SET_ITEM(list,i,item); }
        return list;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        if ([value count]>128) { PyErr_SetString(PyExc_ValueError,"Fixture response dict exceeds limit");return NULL; }
        PyObject *dict=PyDict_New();if (!dict) return NULL;
        for (id key in value) {
            if (![key isKindOfClass:NSString.class]) { PyErr_SetString(PyExc_TypeError,"Fixture response keys must be strings");Py_DECREF(dict);return NULL; }
            PyObject *name=MMToPython(key,depth+1),*item=MMToPython(value[key],depth+1);
            int result=name&&item?PyDict_SetItem(dict,name,item):-1;Py_XDECREF(name);Py_XDECREF(item);
            if (result<0) { Py_DECREF(dict);return NULL; }
        }
        return dict;
    }
    PyErr_SetString(PyExc_TypeError,"Unsupported fixture response value");return NULL;
}

static PyObject *MMTransportError(NSString *kind) {
    PyObject *module=PyImport_ImportModule("requests_adapter");
    PyObject *type=module?PyObject_GetAttrString(module,[kind isEqual:@"protocol"]?"BridgeProtocolError":"BridgeTransportError"):NULL;
    PyObject *error=type?PyObject_CallFunction(type,"s",[kind UTF8String]):NULL;
    if (error) PyErr_SetObject(type,error);
    Py_XDECREF(error);Py_XDECREF(type);Py_XDECREF(module);return NULL;
}

static PyObject *MMTransportCall(PyObject *capsule, PyObject *args) {
    if (!PyTuple_Check(args) || PyTuple_Size(args)!=2) { PyErr_SetString(PyExc_TypeError,"Fixture bridge requires envelope and call context");return NULL; }
    void *pointer=PyCapsule_GetPointer(capsule,"marco.fixture.transport");if (!pointer) return NULL;
    FlutterPythonTransport *transport=(__bridge FlutterPythonTransport *)pointer;
    @autoreleasepool {
        id envelope=MMFromPython(PyTuple_GET_ITEM(args,0),0);if (!envelope) return NULL;
        if (![envelope isKindOfClass:NSDictionary.class]) { PyErr_SetString(PyExc_TypeError,"Fixture envelope must be a dict");return NULL; }
        NSString *error=nil;id response=nil;MMTransportPending *pending=nil;
        PyThreadState *state=PyEval_SaveThread();
        @try { pending=[transport performRequest:envelope error:&error]; }
        @catch (NSException *exception) { (void)exception;error=@"protocol"; }
        @finally { PyEval_RestoreThread(state); }
        if (pending) response=[transport claimResponse:pending error:&error];
        if ([error isEqualToString:@"cancelled"]) {
            PyObject *cancelled=PyObject_CallMethod(PyTuple_GET_ITEM(args,1),"cancel",NULL);
            if (!cancelled) return NULL;
            Py_DECREF(cancelled);
        }
        if (error) return MMTransportError(error);
        if (!response) return MMTransportError(@"protocol");
        return MMToPython(response,0);
    }
}

static void MMTransportCapsuleDestroy(PyObject *capsule) {
    void *pointer=PyCapsule_GetPointer(capsule,"marco.fixture.transport");
    if (pointer) { id released=CFBridgingRelease(pointer);(void)released; }
    else PyErr_Clear();
}

PyObject *MMCreateFixtureTransportBridge(FlutterPythonTransport *transport) {
    static PyMethodDef method={"fixture_transport",MMTransportCall,METH_VARARGS,"Owned asynchronous Dart HTTP fixture bridge"};
    void *retained=(__bridge_retained void *)transport;
    PyObject *capsule=PyCapsule_New(retained,"marco.fixture.transport",MMTransportCapsuleDestroy);
    if (!capsule) { id released=CFBridgingRelease(retained);(void)released;return NULL; }
    PyObject *callable=PyCFunction_NewEx(&method,capsule,NULL);Py_DECREF(capsule);return callable;
}
