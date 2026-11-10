// Experimental feasibility probe. Not a production source runtime or security sandbox.
#import <UIKit/UIKit.h>
#import <Python/Python.h>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cerrno>
#include <signal.h>
#include <unistd.h>

static std::atomic<int> heartbeat{0};
static std::atomic<bool> finished{false};
static std::chrono::steady_clock::time_point traceDeadline;
static NSString *documents;

static void saveJSON(NSDictionary *report, NSString *name) {
    NSData *bytes=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    if (![bytes writeToFile:[documents stringByAppendingPathComponent:name] atomically:YES])
        NSLog(@"CPythonProbe could not write %@",name);
}

static void checkpoint(NSString *phase) {
    saveJSON(@{@"phase":phase,@"heartbeat":@(heartbeat.load())},@"progress.json");
}

static void uncaughtException(NSException *exception) {
    saveJSON(@{@"passed":@NO,@"exception":exception.name?:@"",@"reason":exception.reason?:@"",
               @"stack":exception.callStackSymbols?:@[]},@"exception.json");
}

static NSString *pythonError(void) {
    PyObject *error=PyErr_GetRaisedException();
    if (!error) return @"Python call failed without exception";
    PyObject *text=PyObject_Str(error);
    const char *utf8=text ? PyUnicode_AsUTF8(text) : NULL;
    NSString *message=utf8 ? [NSString stringWithUTF8String:utf8] : @"Python exception could not be formatted";
    Py_XDECREF(text);Py_DECREF(error);PyErr_Clear();return message;
}

static BOOL statusOK(PyStatus status, NSString **failure) {
    if (!PyStatus_Exception(status)) return YES;
    *failure=status.err_msg ? [NSString stringWithUTF8String:status.err_msg] : @"Python initialization failed";
    return NO;
}

static int deadlineTrace(PyObject *, PyFrameObject *, int, PyObject *) {
    if (std::chrono::steady_clock::now() >= traceDeadline) {
        PyErr_SetString(PyExc_TimeoutError,"owned fixture cooperative deadline");return -1;
    }
    return 0;
}

static BOOL evaluate(const char *code, NSString **failure) {
    PyObject *main=PyImport_AddModule("__main__");
    if (!main) { *failure=pythonError();return NO; }
    PyObject *globals=PyModule_GetDict(main);
    PyObject *result=PyRun_String(code,Py_file_input,globals,globals);
    if (!result) { *failure=pythonError();return NO; }
    Py_DECREF(result);return YES;
}

static void addCheck(NSMutableArray *checks, NSString *name, BOOL passed) {
    [checks addObject:@{@"name":name,@"passed":@(passed)}];
}

static NSString *signalDisposition(const struct sigaction &action) {
    if (action.sa_handler==SIG_DFL) return @"default";
    if (action.sa_handler==SIG_IGN) return @"ignored";
    return @"custom";
}

@interface CPythonProbeDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end

@implementation CPythonProbeDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *view=[UIViewController new];view.view.backgroundColor=UIColor.blackColor;
    self.window.rootViewController=view;[self.window makeKeyAndVisible];
    documents=[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES) firstObject];
    [[NSFileManager defaultManager] createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:nil];
    // Fatal CPython startup errors can precede Python's system logger setup.
    // Preserve libc stdout/stderr in this disposable app's own data container.
    freopen([[documents stringByAppendingPathComponent:@"native-stderr.log"] fileSystemRepresentation],"w",stderr);
    freopen([[documents stringByAppendingPathComponent:@"native-stdout.log"] fileSystemRepresentation],"w",stdout);
    setvbuf(stderr,NULL,_IONBF,0);setvbuf(stdout,NULL,_IONBF,0);
    NSSetUncaughtExceptionHandler(uncaughtException);
    checkpoint(@"uikit_did_finish_launching");
    [NSTimer scheduledTimerWithTimeInterval:.02 repeats:YES block:^(NSTimer *) { ++heartbeat; }];
    // This watchdog records failure; it DOES NOT kill a Python thread. Only the
    // external test runner may terminate this dedicated disposable test app.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,45*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if (!finished.load()) saveJSON(@{@"passed":@NO,@"failure":@"Application probe deadline; Python was not forcibly stopped",@"heartbeat":@(heartbeat.load())},@"watchdog.json");
    });
    NSThread *worker=[[NSThread alloc] initWithBlock:^{ @autoreleasepool { [self runProbe]; } }];
    worker.name=@"experimental-cpython-probe";worker.stackSize=8*1024*1024;[worker start];return YES;
}

- (void)runProbe {
    NSString *failure=nil;NSMutableArray *checks=[NSMutableArray array];
    NSMutableDictionary *report=[@{@"passed":@NO,@"checks":checks,@"scope":@"Experimental native app; no Flutter integration or physical-device acceptance"} mutableCopy];
#if defined(__arm64__) || defined(__aarch64__)
    report[@"native_arch"]=@"arm64";
#else
    report[@"native_arch"]=@"x86_64";
#endif
    NSString *bundle=NSBundle.mainBundle.resourcePath;
    PyPreConfig pre;PyPreConfig_InitIsolatedConfig(&pre);pre.utf8_mode=1;
    PyConfig config;PyConfig_InitIsolatedConfig(&config);
    config.write_bytecode=0;config.buffered_stdio=0;config.install_signal_handlers=0;
    config.site_import=0;config.parse_argv=0;config.use_system_logger=1;
    BOOL initialized=NO;
    struct sigaction pipeBefore={},pipePolicy={},pipeAfter={},interruptBefore={},interruptAfter={};
    checkpoint(@"host_signal_policy");
    if (sigaction(SIGPIPE,NULL,&pipeBefore)!=0 || sigaction(SIGINT,NULL,&interruptBefore)!=0) {
        failure=@"Could not inspect host signal dispositions";goto done;
    }
    report[@"sigpipe_before_policy"]=signalDisposition(pipeBefore);
    report[@"sigint_before_python"]=signalDisposition(interruptBefore);
    // Isolated embedding disables CPython's signal installation, including its
    // normal SIGPIPE ignore. Own only this disposable host's SIGPIPE policy:
    // disconnected writes must raise EPIPE, not terminate the UIKit process.
    // SIGINT remains with the host; this is not a production app signal change.
    pipePolicy.sa_handler=SIG_IGN;sigemptyset(&pipePolicy.sa_mask);
    if (sigaction(SIGPIPE,&pipePolicy,NULL)!=0 || sigaction(SIGPIPE,NULL,&pipeAfter)!=0) {
        failure=@"Could not configure host SIGPIPE policy";goto done;
    }
    report[@"sigpipe_after_policy"]=signalDisposition(pipeAfter);
    addCheck(checks,@"host_sigpipe_ignored_before_python",pipeAfter.sa_handler==SIG_IGN);
    {
        int descriptors[2];
        if (pipe(descriptors)!=0) { failure=@"Could not create owned closed-pipe fixture";goto done; }
        close(descriptors[0]);errno=0;
        const ssize_t written=write(descriptors[1],"x",1);const int writeError=errno;
        close(descriptors[1]);
        addCheck(checks,@"closed_pipe_returns_epipe",written==-1 && writeError==EPIPE);
    }
    checkpoint(@"python_preinitialize");
    if (!statusOK(Py_PreInitialize(&pre),&failure)) goto done;
    if (!statusOK(PyConfig_SetBytesString(&config,&config.home,[[bundle stringByAppendingPathComponent:@"python"] UTF8String]),&failure)) goto done;
    if (!statusOK(PyConfig_SetBytesString(&config,&config.program_name,"CPythonProbe"),&failure)) goto done;
    // AppleFrameworkLoader resolves .fwork records relative to sys.executable.
    if (!statusOK(PyConfig_SetBytesString(&config,&config.executable,NSBundle.mainBundle.executablePath.UTF8String),&failure)) goto done;
    for (NSString *relative in @[@"python/lib/python3.14",@"python/lib/python3.14/lib-dynload",@"app_packages",@"app"]) {
        wchar_t *path=Py_DecodeLocale([[bundle stringByAppendingPathComponent:relative] UTF8String],NULL);
        if (!path) { failure=@"Path decoding failed";goto done; }
        PyStatus status=PyWideStringList_Append(&config.module_search_paths,path);PyMem_RawFree(path);
        if (!statusOK(status,&failure)) goto done;
    }
    config.module_search_paths_set=1;
    checkpoint(@"python_initialize");
    if (!statusOK(Py_InitializeFromConfig(&config),&failure)) goto done;
    initialized=YES;
    checkpoint(@"python_initialized");
    if (sigaction(SIGPIPE,NULL,&pipeAfter)!=0 || sigaction(SIGINT,NULL,&interruptAfter)!=0) {
        failure=@"Could not verify embedded signal dispositions";goto done;
    }
    report[@"sigpipe_after_python"]=signalDisposition(pipeAfter);
    report[@"sigint_after_python"]=signalDisposition(interruptAfter);
    addCheck(checks,@"python_preserves_host_signal_dispositions",
             pipeAfter.sa_handler==SIG_IGN && interruptAfter.sa_handler==interruptBefore.sa_handler
             && interruptAfter.sa_flags==interruptBefore.sa_flags);
    report[@"runtime"]=[NSString stringWithUTF8String:Py_GetVersion()];
    addCheck(checks,@"pinned_python_3_14_10",[report[@"runtime"] hasPrefix:@"3.14.10 "]);
    {
        checkpoint(@"faulthandler_enable");
        PyObject *fault=PyImport_ImportModule("faulthandler");
        if (!fault) { failure=pythonError();goto done; }
        // Explicit fd 2 avoids relying on the iOS system logger's Python stream.
        // It was redirected above to this app's own native-stderr.log.
        PyObject *enabled=PyObject_CallMethod(fault,"enable","i",2);Py_DECREF(fault);
        if (!enabled) { failure=pythonError();goto done; }
        Py_DECREF(enabled);
        PyObject *path=PyUnicode_FromString([[documents stringByAppendingPathComponent:@"python-progress.log"] UTF8String]);
        if (!path || PySys_SetObject("_marco_probe_progress",path)<0) {
            Py_XDECREF(path);failure=pythonError();goto done;
        }
        Py_DECREF(path);
    }
    {
        checkpoint(@"fixture_import_and_run");
        PyObject *module=PyImport_ImportModule("probe_fixture");
        if (!module) { failure=pythonError();goto done; }
        PyObject *callable=PyObject_GetAttrString(module,"run_probe");Py_DECREF(module);
        NSString *work=[documents stringByAppendingPathComponent:@"state"];
        PyObject *arg=PyUnicode_FromString(work.UTF8String);
        PyObject *result=callable&&arg ? PyObject_CallOneArg(callable,arg) : NULL;
        Py_XDECREF(arg);Py_XDECREF(callable);
        if (!result) { failure=pythonError();goto done; }
        const char *text=PyUnicode_AsUTF8(result);
        NSData *data=text ? [[NSString stringWithUTF8String:text] dataUsingEncoding:NSUTF8StringEncoding] : nil;
        NSDictionary *fixture=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        Py_DECREF(result);
        if (![fixture isKindOfClass:NSDictionary.class]) { failure=@"Fixture did not return valid JSON";goto done; }
        report[@"fixture"]=fixture;[checks addObjectsFromArray:fixture[@"checks"]];
        checkpoint(@"fixture_completed");
    }
    // Both examples use only owned synthetic code. The trace hook is cooperative,
    // can be removed by Python, and cannot interrupt arbitrary blocking C calls.
    {
        checkpoint(@"cooperative_deadline_checks");
        if (!evaluate("import time\n_probe_main_marker = 'main'\n",&failure)) goto done;
        PyObject *globals=PyModule_GetDict(PyImport_AddModule("__main__"));
        auto start=std::chrono::steady_clock::now();traceDeadline=start+std::chrono::milliseconds(100);
        PyEval_SetTrace(deadlineTrace,NULL);
        PyObject *result=PyRun_String("counter=0\nwhile True:\n counter += 1\n",Py_file_input,globals,globals);
        BOOL timedOut=!result&&PyErr_ExceptionMatches(PyExc_TimeoutError);
        PyEval_SetTrace(NULL,NULL);Py_XDECREF(result);PyErr_Clear();
        auto ms=std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-start).count();
        addCheck(checks,@"cooperative_python_loop_timeout",timedOut&&ms>=80&&ms<1500);
        report[@"cooperative_timeout_ms"]=@(ms);
        start=std::chrono::steady_clock::now();traceDeadline=start+std::chrono::milliseconds(20);
        PyEval_SetTrace(deadlineTrace,NULL);
        result=PyRun_String("time.sleep(0.15)\nafter_sleep=1\n",Py_file_input,globals,globals);
        timedOut=!result&&PyErr_ExceptionMatches(PyExc_TimeoutError);
        PyEval_SetTrace(NULL,NULL);Py_XDECREF(result);PyErr_Clear();
        ms=std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-start).count();
        addCheck(checks,@"blocking_c_call_exceeds_trace_deadline",timedOut&&ms>=120);
        report[@"non_interruptible_sleep_ms"]=@(ms);
    }
    {
        checkpoint(@"subinterpreter_create");
        PyThreadState *mainState=PyThreadState_Get();
        PyInterpreterConfig isolation={};isolation.use_main_obmalloc=0;
        isolation.allow_fork=0;isolation.allow_exec=0;isolation.allow_threads=1;
        isolation.allow_daemon_threads=0;isolation.check_multi_interp_extensions=1;
        isolation.gil=PyInterpreterConfig_OWN_GIL;
        PyThreadState *sub=NULL;
        PyStatus status=Py_NewInterpreterFromConfig(&sub,&isolation);
        if (!statusOK(status,&failure)) {
            if (!PyThreadState_GetUnchecked()) PyEval_RestoreThread(mainState);
            goto done;
        }
        checkpoint(@"subinterpreter_imports");
        NSString *subFailure=nil;
        BOOL isolated=evaluate("import sys\nassert '_probe_main_marker' not in globals()\n_probe_sub_marker='sub'\nimport json, ssl, socket, requests\nfrom bs4 import BeautifulSoup\nassert BeautifulSoup('<b>ok</b>','html.parser').b.text == 'ok'\n",&subFailure);
        // No Python work remains in this interpreter, so ending it is safe here.
        // This is not cancellation of a running source.
        checkpoint(@"subinterpreter_end");
        Py_EndInterpreter(sub);
        checkpoint(@"main_interpreter_restore");
        PyEval_RestoreThread(mainState);
        addCheck(checks,@"isolated_interpreter_pure_dependencies",isolated);
        if (!isolated) { failure=subFailure;goto done; }
        if (!evaluate("assert _probe_main_marker == 'main'\nassert '_probe_sub_marker' not in globals()\n",&failure)) goto done;
        addCheck(checks,@"main_interpreter_state_preserved",YES);
    }
    addCheck(checks,@"ui_main_thread_remained_responsive",heartbeat.load()>=5);
done:
    checkpoint(@"write_result");
    PyConfig_Clear(&config);
    if (initialized) {
        // Keep process-wide CPython alive; do not finalize during active app life.
        // The external test runner terminates this disposable app after the report.
        if (PyErr_Occurred()) PyErr_Clear();
        PyEval_SaveThread();
    }
    BOOL passed=initialized&&failure==nil;
    for (NSDictionary *entry in checks) if (![entry[@"passed"] boolValue]) passed=NO;
    report[@"passed"]=@(passed);report[@"failure"]=failure?:@"";report[@"heartbeat"]=@(heartbeat.load());
    report[@"limitations"]=@[@"No hard in-process thread cancellation",@"Subinterpreters share process and app filesystem permissions",@"No lxml or Crypto native wheels bundled",@"No real media decoding, external-source compatibility, physical iOS14 or Flutter UI result"];
    saveJSON(report,@"result.json");finished=true;
}
@end

int main(int argc,char **argv) {
    @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(CPythonProbeDelegate.class)); }
}
