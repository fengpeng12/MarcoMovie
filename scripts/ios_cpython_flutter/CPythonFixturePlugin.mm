// Experimental: accepts only the bundled synthetic-v1 fixture, never user code.
#import "CPythonFixturePlugin.h"
#import "FlutterPythonTransport.h"
#import <Python/Python.h>
#include <signal.h>

@interface MMFixtureSession : NSObject
@property(nonatomic,assign) PyThreadState *state;
@property(nonatomic,assign) PyObject *module;
@property(nonatomic,assign) PyObject *spider;
@property(nonatomic,assign) BOOL nativeSource;
@property(nonatomic,copy) NSString *origin;
@end
@implementation MMFixtureSession
@end

static NSString *pyError(void) {
    PyObject *error=PyErr_GetRaisedException();
    PyObject *text=error?PyObject_Str(error):NULL;
    const char *utf8=text?PyUnicode_AsUTF8(text):NULL;
    NSString *message=utf8?[NSString stringWithUTF8String:utf8]:@"Python operation failed";
    Py_XDECREF(text);Py_XDECREF(error);PyErr_Clear();
    return message.length>1024?[message substringToIndex:1024]:message;
}

static BOOL keysAre(NSDictionary *value, NSArray *keys) {
    return value.count==keys.count && [[NSSet setWithArray:value.allKeys] isEqualToSet:[NSSet setWithArray:keys]];
}

static NSString *disposition(const struct sigaction &value) {
    return value.sa_handler==SIG_IGN?@"ignored":value.sa_handler==SIG_DFL?@"default":@"custom";
}

static NSDictionary *signals(void) {
    struct sigaction pipe={},interrupt={};
    if (sigaction(SIGPIPE,NULL,&pipe)!=0 || sigaction(SIGINT,NULL,&interrupt)!=0) return @{@"error":@YES};
    return @{@"sigpipe":disposition(pipe),@"sigint":disposition(interrupt)};
}

static PyObject *fromJSON(id value) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if (!data || data.length>64*1024) { PyErr_SetString(PyExc_ValueError,"Invalid fixture arguments");return NULL; }
    PyObject *json=PyImport_ImportModule("json");
    PyObject *text=PyUnicode_DecodeUTF8((const char *)data.bytes,data.length,"strict");
    PyObject *result=json&&text?PyObject_CallMethod(json,"loads","O",text):NULL;
    Py_XDECREF(json);Py_XDECREF(text);return result;
}

static id toJSON(PyObject *value) {
    PyObject *json=PyImport_ImportModule("json");
    PyObject *text=json?PyObject_CallMethod(json,"dumps","O",value):NULL;
    Py_XDECREF(json);
    Py_ssize_t size=0;const char *utf8=text?PyUnicode_AsUTF8AndSize(text,&size):NULL;
    id result=nil;
    if (utf8 && size<=1024*1024) result=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:utf8 length:size] options:NSJSONReadingFragmentsAllowed error:nil];
    Py_XDECREF(text);
    if (!result && !PyErr_Occurred()) PyErr_SetString(PyExc_ValueError,"Fixture result exceeds JSON contract");
    return result;
}

@interface CPythonFixturePlugin ()
@property(nonatomic,strong) NSThread *worker;
@property(nonatomic,strong) NSMutableDictionary<NSString *,MMFixtureSession *> *sessions;
@property(nonatomic,assign) PyThreadState *mainState;
@property(nonatomic,copy) NSString *failure;
@property(nonatomic,copy) NSString *runtime;
@property(nonatomic,strong) NSDictionary *beforePython;
@property(nonatomic,strong) NSDictionary *afterPython;
@property(nonatomic,assign) BOOL preservedInterrupt;
@property(nonatomic,strong) FlutterPythonTransport *transport;
@end

@implementation CPythonFixturePlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    FlutterMethodChannel *channel=[FlutterMethodChannel methodChannelWithName:@"marco_movie/experimental_python" binaryMessenger:registrar.messenger];
    CPythonFixturePlugin *plugin=[[self alloc] init];
    plugin.transport=[[FlutterPythonTransport alloc] initWithChannel:channel];
    [registrar addMethodCallDelegate:plugin channel:channel];
}
- (instancetype)init {
    if ((self=[super init])) {
        _sessions=[NSMutableDictionary dictionary];
        _worker=[[NSThread alloc] initWithTarget:self selector:@selector(workerMain) object:nil];
        _worker.name=@"experimental-python-fixtures";_worker.stackSize=8*1024*1024;[_worker start];
    }
    return self;
}
- (void)workerMain {
    @autoreleasepool {
        NSRunLoop *loop=NSRunLoop.currentRunLoop;
        [loop addPort:[NSPort port] forMode:NSDefaultRunLoopMode];
        while (YES) { @autoreleasepool { [loop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]; } }
    }
}
- (void)initializePython {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.pilipala.experimental.cpythonflutter"]) {
        self.failure=@"Fixture plugin may run only in its disposable experiment app";return;
    }
    struct sigaction action={},interruptBefore={},interruptAfter={};action.sa_handler=SIG_IGN;sigemptyset(&action.sa_mask);
    self.beforePython=signals();
    if (sigaction(SIGINT,NULL,&interruptBefore)!=0) { self.failure=@"Host SIGINT inspection failed";return; }
    if (sigaction(SIGPIPE,&action,NULL)!=0) { self.failure=@"Host SIGPIPE policy failed";return; }
    NSString *bundle=NSBundle.mainBundle.resourcePath;
    PyPreConfig pre;PyPreConfig_InitIsolatedConfig(&pre);pre.utf8_mode=1;
    PyConfig config;PyConfig_InitIsolatedConfig(&config);
    config.write_bytecode=0;config.buffered_stdio=0;config.install_signal_handlers=0;
    config.site_import=0;config.parse_argv=0;config.use_system_logger=1;
    PyStatus status=Py_PreInitialize(&pre);
    if (PyStatus_Exception(status)) goto failed;
    status=PyConfig_SetBytesString(&config,&config.home,[[bundle stringByAppendingPathComponent:@"python"] UTF8String]);
    if (PyStatus_Exception(status)) goto failed;
    status=PyConfig_SetBytesString(&config,&config.executable,NSBundle.mainBundle.executablePath.UTF8String);
    if (PyStatus_Exception(status)) goto failed;
    for (NSString *relative in @[@"python/lib/python3.14",@"python/lib/python3.14/lib-dynload",@"app_packages",@"app"]) {
        wchar_t *path=Py_DecodeLocale([[bundle stringByAppendingPathComponent:relative] UTF8String],NULL);
        if (!path) { self.failure=@"Fixture module path decoding failed";PyConfig_Clear(&config);return; }
        status=PyWideStringList_Append(&config.module_search_paths,path);PyMem_RawFree(path);
        if (PyStatus_Exception(status)) goto failed;
    }
    config.module_search_paths_set=1;status=Py_InitializeFromConfig(&config);
    if (PyStatus_Exception(status)) goto failed;
    PyConfig_Clear(&config);self.runtime=[NSString stringWithUTF8String:Py_GetVersion()];
    self.afterPython=signals();
    self.preservedInterrupt=sigaction(SIGINT,NULL,&interruptAfter)==0 && interruptBefore.sa_handler==interruptAfter.sa_handler && interruptBefore.sa_flags==interruptAfter.sa_flags;
    self.mainState=PyEval_SaveThread();return;
failed:
    self.failure=status.err_msg?[NSString stringWithUTF8String:status.err_msg]:@"Fixture Python initialization failed";
    PyConfig_Clear(&config);
}
- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
    if ([call.method isEqualToString:@"cancelTransport"]) {
        NSDictionary *args=[call.arguments isKindOfClass:NSDictionary.class]?call.arguments:nil;
        NSString *identity=[args[@"callId"] isKindOfClass:NSString.class]?args[@"callId"]:nil;
        NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.pilipala.experimental.cpythonflutter"]
                || !keysAre(args,@[@"version",@"callId"]) || ![args[@"version"] isEqual:@1]
                || CFGetTypeID((__bridge CFTypeRef)args[@"version"])==CFBooleanGetTypeID()
                || identity.length!=32 || [identity rangeOfCharacterFromSet:allowed.invertedSet].location!=NSNotFound) {
            result([FlutterError errorWithCode:@"invalid_request" message:@"Invalid owned transport cancellation" details:nil]);return;
        }
        // Do not queue behind the Python owner: it can be waiting for this signal.
        NSUInteger count=[self.transport cancelCall:identity];
        result(@{@"cancelled":@(count)});return;
    }
    if (![@[@"capabilities",@"open",@"call",@"release",@"transportProbe",@"openSource",@"callSource"] containsObject:call.method]) {
        result(FlutterMethodNotImplemented);return;
    }
    [self performSelector:@selector(execute:) onThread:self.worker withObject:@{@"method":call.method,@"arguments":call.arguments?:NSNull.null,@"result":[result copy]} waitUntilDone:NO];
}
- (void)execute:(NSDictionary *)job {
    @autoreleasepool {
        FlutterResult reply=job[@"result"];id output=nil;NSString *code=nil,*message=nil;
        NSDictionary *args=[job[@"arguments"] isKindOfClass:NSDictionary.class]?job[@"arguments"]:nil;
        NSString *method=job[@"method"];
        BOOL inspectOnly=[method isEqualToString:@"capabilities"] && keysAre(args,@[@"initialize"]) && [args[@"initialize"] isEqual:@NO];
        if (!inspectOnly && !self.mainState && !self.failure) [self initializePython];
        if (self.failure) { code=@"runtime_unavailable";message=self.failure; }
        else if ([method isEqualToString:@"capabilities"]) {
            NSString *documents=[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES) firstObject];
            [[NSFileManager defaultManager] createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:nil];
#if defined(__arm64__) || defined(__aarch64__)
            NSString *arch=@"arm64";
#else
            NSString *arch=@"x86_64";
#endif
            NSData *orderData=[NSData dataWithContentsOfFile:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"fixture-order.json"]];
            id order=orderData?[NSJSONSerialization JSONObjectWithData:orderData options:NSJSONReadingFragmentsAllowed error:nil]:nil;
            if (![@[@"python-first",@"node-first"] containsObject:order?:NSNull.null]) { code=@"invalid_fixture_order"; }
            else output=@{@"version":@1,@"runtime":self.runtime?:@"",@"arch":arch,@"ownedFixtureOnly":@YES,
                     @"hardCancel":@NO,@"sourceThreads":@NO,@"maxSessions":@2,@"documents":documents,
                     @"initialized":@(self.mainState!=NULL),@"order":order,@"signals":signals(),
                     @"signalsBeforePython":self.beforePython?:@{},@"signalsAfterPython":self.afterPython?:@{},
                     @"pythonPreservedSigint":@(self.preservedInterrupt)};
        } else if (![args[@"version"] isEqual:@1]) { code=@"invalid_request"; }
        else if ([method isEqualToString:@"transportProbe"]) {
            NSArray *origins=[args[@"origins"] isKindOfClass:NSArray.class]?args[@"origins"]:nil;
            BOOL valid=keysAre(args,@[@"version",@"origins"]) && origins.count==2
                && CFGetTypeID((__bridge CFTypeRef)args[@"version"])!=CFBooleanGetTypeID();
            NSMutableSet *ports=[NSMutableSet set];
            NSRegularExpression *path=[NSRegularExpression regularExpressionWithPattern:@"^/[a-f0-9]{32}$" options:0 error:nil];
            for (id item in origins) {
                NSURLComponents *url=[item isKindOfClass:NSString.class]?[NSURLComponents componentsWithString:item]:nil;
                if (!url || ![url.scheme isEqualToString:@"http"] || ![url.host isEqualToString:@"127.0.0.1"]
                        || url.port.integerValue<=0 || url.port.integerValue>65535 || url.user || url.password || url.query || url.fragment
                        || ![url.percentEncodedPath isEqualToString:url.path]
                        || [path numberOfMatchesInString:url.path options:0 range:NSMakeRange(0,url.path.length)]!=1) { valid=NO;break; }
                [ports addObject:url.port];
            }
            if (!valid || ports.count!=2) code=@"invalid_request";
            else if (self.sessions.count>=2) code=@"runtime_limit";
            else if (![self.transport beginOrigins:origins]) code=@"runtime_limit";
            else {
                PyEval_RestoreThread(self.mainState);
                PyInterpreterConfig isolation={};isolation.use_main_obmalloc=0;isolation.allow_fork=0;isolation.allow_exec=0;
                isolation.allow_threads=0;isolation.allow_daemon_threads=0;isolation.check_multi_interp_extensions=1;isolation.gil=PyInterpreterConfig_OWN_GIL;
                PyThreadState *state=NULL;PyStatus status=Py_NewInterpreterFromConfig(&state,&isolation);
                if (PyStatus_Exception(status)) {
                    code=@"python_error";message=status.err_msg?[NSString stringWithUTF8String:status.err_msg]:@"Transport subinterpreter creation failed";
                    if (!PyThreadState_GetUnchecked()) PyEval_RestoreThread(self.mainState);
                } else {
                    PyObject *module=PyImport_ImportModule("transport_fixture");
                    PyObject *bridge=module?MMCreateFixtureTransportBridge(self.transport):NULL;
                    PyObject *addresses=bridge?fromJSON(origins):NULL;
                    PyObject *value=addresses?PyObject_CallMethod(module,"run","OO",bridge,addresses):NULL;
                    if (value) { output=toJSON(value);Py_DECREF(value); }
                    if (!output) { code=@"python_error";message=pyError(); }
                    Py_XDECREF(addresses);Py_XDECREF(bridge);Py_XDECREF(module);
                    Py_EndInterpreter(state);PyEval_RestoreThread(self.mainState);
                }
                self.mainState=PyEval_SaveThread();[self.transport endProbe];
            }
        }
        else if ([method isEqualToString:@"open"] || [method isEqualToString:@"openSource"]) {
            BOOL nativeSource=[method isEqualToString:@"openSource"];
            NSURLComponents *url=[args[@"origin"] isKindOfClass:NSString.class]?[NSURLComponents componentsWithString:args[@"origin"]]:nil;
            NSRegularExpression *path=[NSRegularExpression regularExpressionWithPattern:@"^/[a-f0-9]{32}$" options:0 error:nil];
            BOOL origin=url && [url.scheme isEqualToString:@"http"] && [url.host isEqualToString:@"127.0.0.1"] && url.port.integerValue>0 && url.port.integerValue<=65535 && !url.user && !url.password && !url.query && !url.fragment && [path numberOfMatchesInString:url.path options:0 range:NSMakeRange(0,url.path.length)]==1;
            if (!keysAre(args,@[@"version",@"source",@"origin"])
                    || CFGetTypeID((__bridge CFTypeRef)args[@"version"])==CFBooleanGetTypeID()
                    || ![args[@"source"] isEqual:nativeSource?@"native-source-v1":@"synthetic-v1"] || !origin) code=@"invalid_request";
            else if (self.sessions.count>=2) code=@"runtime_limit";
            else {
                PyEval_RestoreThread(self.mainState);
                PyInterpreterConfig isolation={};isolation.use_main_obmalloc=0;isolation.allow_fork=0;isolation.allow_exec=0;
                isolation.allow_threads=0;isolation.allow_daemon_threads=0;isolation.check_multi_interp_extensions=1;isolation.gil=PyInterpreterConfig_OWN_GIL;
                PyThreadState *state=NULL;PyStatus status=Py_NewInterpreterFromConfig(&state,&isolation);
                if (PyStatus_Exception(status)) {
                    code=@"python_error";message=status.err_msg?[NSString stringWithUTF8String:status.err_msg]:@"Subinterpreter creation failed";
                    if (!PyThreadState_GetUnchecked()) PyEval_RestoreThread(self.mainState);
                } else {
                    PyObject *module=PyImport_ImportModule(nativeSource?"source_session_fixture":"session_fixture");
                    PyObject *bridge=module&&nativeSource?MMCreateFixtureTransportBridge(self.transport):NULL;
                    NSString *handle=NSUUID.UUID.UUIDString;
                    NSString *proxy=[NSString stringWithFormat:@"%@/proxy?do=py&siteKey=%@",args[@"origin"],handle];
                    PyObject *spider=NULL;
                    if (nativeSource) {
                        if (bridge) spider=PyObject_CallMethod(module,"create","ssO",[args[@"origin"] UTF8String],proxy.UTF8String,bridge);
                    } else if (module) spider=PyObject_CallMethod(module,"create","s",[args[@"origin"] UTF8String]);
                    Py_XDECREF(bridge);
                    if (!spider) {
                        code=@"python_error";message=pyError();Py_XDECREF(module);Py_EndInterpreter(state);PyEval_RestoreThread(self.mainState);
                    } else {
                        MMFixtureSession *session=[MMFixtureSession new];session.module=module;session.spider=spider;
                        session.nativeSource=nativeSource;session.origin=args[@"origin"];session.state=PyEval_SaveThread();
                        PyEval_RestoreThread(self.mainState);
                        self.sessions[handle]=session;output=@{@"handle":handle};
                    }
                }
                self.mainState=PyEval_SaveThread();
            }
        } else {
            NSString *handle=[args[@"handle"] isKindOfClass:NSString.class]?args[@"handle"]:nil;
            MMFixtureSession *session=handle?self.sessions[handle]:nil;
            if ([method isEqualToString:@"release"] && keysAre(args,@[@"version",@"handle"])) {
                if (session) {
                    [self.sessions removeObjectForKey:handle];PyEval_RestoreThread(session.state);
                    PyObject *closed=PyObject_CallMethod(session.module,"close","O",session.spider);
                    if (!closed) { code=@"python_error";message=pyError(); }Py_XDECREF(closed);
                    Py_DECREF(session.spider);Py_DECREF(session.module);Py_EndInterpreter(session.state);
                    session.state=NULL;session.spider=NULL;session.module=NULL;
                }
                output=@{@"released":@(session!=nil)};
            } else if (([method isEqualToString:@"call"] || [method isEqualToString:@"callSource"])
                    && keysAre(args,[method isEqualToString:@"callSource"]?@[@"version",@"handle",@"method",@"args",@"callId"]:@[@"version",@"handle",@"method",@"args"])
                    && CFGetTypeID((__bridge CFTypeRef)args[@"version"])!=CFBooleanGetTypeID()
                    && [args[@"args"] isKindOfClass:NSArray.class] && [@[@"home",@"homeVod",@"category",@"search",@"detail",@"play",@"proxy",@"liveContent"] containsObject:args[@"method"]]) {
                if (!session) code=@"invalid_handle";
                else if (session.nativeSource!=[method isEqualToString:@"callSource"]) code=@"invalid_request";
                else if (session.nativeSource && (![args[@"callId"] isKindOfClass:NSString.class]
                        || [args[@"callId"] length]!=32
                        || [args[@"callId"] rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location!=NSNotFound)) code=@"invalid_request";
                else if (session.nativeSource && ![self.transport beginOrigins:@[session.origin]]) code=@"runtime_limit";
                else {
                    PyEval_RestoreThread(session.state);PyObject *arguments=fromJSON(args[@"args"]);
                    PyObject *value=NULL;
                    if (arguments) {
                        value=session.nativeSource?PyObject_CallMethod(session.module,"dispatch","OsOs",session.spider,[args[@"method"] UTF8String],arguments,[args[@"callId"] UTF8String])
                            :PyObject_CallMethod(session.module,"dispatch","OsO",session.spider,[args[@"method"] UTF8String],arguments);
                    }
                    Py_XDECREF(arguments);if (value) { output=toJSON(value);Py_DECREF(value); }
                    if (!output) { code=@"python_error";message=pyError(); }
                    session.state=PyEval_SaveThread();
                    if (session.nativeSource) [self.transport endProbe];
                }
            } else code=@"invalid_request";
        }
        id answer=code?[FlutterError errorWithCode:code message:message?:@"Invalid owned fixture operation" details:nil]:output;
        dispatch_async(dispatch_get_main_queue(),^{ reply(answer); });
    }
}
@end
