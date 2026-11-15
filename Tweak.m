// PiliProbe 0.4: distinguishes between Dart isolate init failure and Vsync/render signal loss.
// New in 0.4: hooks FlutterEngine run/init, tracks handler enter/exit/reply, adds a CADisplayLink
// control probe, and records engine running state.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <execinfo.h>
#import <signal.h>
#import <dlfcn.h>
#import <pthread.h>
#import <sys/utsname.h>
#import <sys/resource.h>
#import <fcntl.h>
#import <unistd.h>
#import <QuartzCore/QuartzCore.h>
#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#endif

static int gLogFD = -1;
static NSString *gLogPath;
static CFAbsoluteTime gStart;
static volatile BOOL gSawFinish, gSawActive, gSawWindow, gSawFlutterLoad, gSawFlutterAppear;
static dispatch_source_t gTimer;
static void (*gPrevExc)(NSException *);
static BOOL gHooked, gMsgHooked;
static volatile unsigned gLines;

static NSObject *gLock;
static NSMutableDictionary *gPending;
static uint64_t gSeq;
static unsigned long gMsgIn, gMsgOut, gHandlerEnter, gHandlerExit, gHandlerReply;

// CADisplayLink control probe
static CADisplayLink *gDisplayLink;
static NSUInteger gDisplayLinkTicks;
static NSUInteger gDisplayLinkLastTicks;
static CFAbsoluteTime gDisplayLinkLastTime;

static void PPLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void PPLog(NSString *fmt, ...) {
    if (gLines++ > 8000) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[+%.2fs] %@\n", CFAbsoluteTimeGetCurrent() - gStart, msg];
    const char *c = line.UTF8String;
    if (gLogFD >= 0 && c) write(gLogFD, c, strlen(c));
}

static void PPSignal(int sig) {
    char head[64];
    int n = snprintf(head, sizeof head, "\n!!! CRASH signal %d\n", sig);
    if (gLogFD >= 0) {
        write(gLogFD, head, n);
        void *bt[64];
        int cnt = backtrace(bt, 64);
        backtrace_symbols_fd(bt, cnt, gLogFD);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static void PPException(NSException *e) {
    PPLog(@"!!! UNCAUGHT EXCEPTION %@: %@\n%@", e.name, e.reason, e.callStackSymbols);
    if (gPrevExc) gPrevExc(e);
}

static int PPThreadCount(void) {
    thread_act_array_t list = NULL;
    mach_msg_type_number_t cnt = 0;
    if (task_threads(mach_task_self(), &list, &cnt) != KERN_SUCCESS) return -1;
    vm_deallocate(mach_task_self(), (vm_address_t)list, cnt * sizeof(thread_t));
    return (int)cnt;
}

static double PPCpuSeconds(void) {
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    return ru.ru_utime.tv_sec + ru.ru_utime.tv_usec / 1e6 + ru.ru_stime.tv_sec + ru.ru_stime.tv_usec / 1e6;
}

static void PPLogImages(const char *label) {
    const char *bp = NSBundle.mainBundle.bundlePath.fileSystemRepresentation;
    size_t bl = strlen(bp);
    uint32_t n = _dyld_image_count();
    NSMutableArray *names = [NSMutableArray array];
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (nm && strncmp(nm, bp, bl) == 0 && strlen(nm) > bl + 1) {
            [names addObject:[NSString stringWithUTF8String:nm + bl + 1]];
        }
    }
    PPLog(@"%s: %u images loaded, %lu from the app bundle: %@", label, n,
          (unsigned long)names.count, [names componentsJoinedByString:@", "]);
}

// ---------- thread dump ----------
#define PP_MAXT 48
#define PP_MAXF 14
static uintptr_t gFrames[PP_MAXT][PP_MAXF];
static int gNF[PP_MAXT];
static char gTName[PP_MAXT][64];
static double gTCpu[PP_MAXT];
static int gTState[PP_MAXT];

static uintptr_t PPStrip(uintptr_t p) {
#if __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip((void *)p, ptrauth_key_function_pointer);
#else
    return p;
#endif
}

static BOOL PPReadWord(uintptr_t addr, uintptr_t *out) {
    vm_size_t sz = 0;
    return vm_read_overwrite(mach_task_self(), (vm_address_t)addr, sizeof(uintptr_t),
                             (vm_address_t)out, &sz) == KERN_SUCCESS && sz == sizeof(uintptr_t);
}

static void PPDumpThreads(void) {
    thread_act_array_t list = NULL;
    mach_msg_type_number_t cnt = 0;
    if (task_threads(mach_task_self(), &list, &cnt) != KERN_SUCCESS) return;
    if (cnt > PP_MAXT) cnt = PP_MAXT;
    thread_t me = mach_thread_self();

    for (mach_msg_type_number_t i = 0; i < cnt; i++) {
        gTName[i][0] = 0;
        pthread_t pt = pthread_from_mach_thread_np(list[i]);
        if (pt) pthread_getname_np(pt, gTName[i], sizeof gTName[i]);
        thread_basic_info_data_t bi;
        mach_msg_type_number_t bic = THREAD_BASIC_INFO_COUNT;
        gTCpu[i] = -1; gTState[i] = 0;
        if (thread_info(list[i], THREAD_BASIC_INFO, (thread_info_t)&bi, &bic) == KERN_SUCCESS) {
            gTCpu[i] = bi.user_time.seconds + bi.user_time.microseconds / 1e6
                     + bi.system_time.seconds + bi.system_time.microseconds / 1e6;
            gTState[i] = bi.run_state;
        }
    }

    for (mach_msg_type_number_t i = 0; i < cnt; i++) {
        gNF[i] = 0;
        if (list[i] == me) continue;
        if (thread_suspend(list[i]) != KERN_SUCCESS) continue;
        arm_thread_state64_t st;
        mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
        if (thread_get_state(list[i], ARM_THREAD_STATE64, (thread_state_t)&st, &sc) == KERN_SUCCESS) {
            int n = 0;
            gFrames[i][n++] = PPStrip(arm_thread_state64_get_pc(st));
            uintptr_t lr = PPStrip(arm_thread_state64_get_lr(st));
            if (lr) gFrames[i][n++] = lr;
            uintptr_t fp = arm_thread_state64_get_fp(st);
            while (fp && (fp & 0xF) == 0 && n < PP_MAXF) {
                uintptr_t next = 0, ret = 0;
                if (!PPReadWord(fp, &next) || !PPReadWord(fp + 8, &ret)) break;
                ret = PPStrip(ret);
                if (!ret) break;
                gFrames[i][n++] = ret;
                if (next <= fp) break;
                fp = next;
            }
            gNF[i] = n;
        }
        thread_resume(list[i]);
    }

    static const char *kState[] = {"?", "running", "stopped", "waiting", "uninterruptible", "halted"};
    for (mach_msg_type_number_t i = 0; i < cnt; i++) {
        int s = gTState[i];
        PPLog(@"thread %u name='%s' state=%s cpu=%.2fs%s", i, gTName[i],
              (s >= 0 && s <= 5) ? kState[s] : "?", gTCpu[i], list[i] == me ? " (probe thread)" : "");
        for (int f = 0; f < gNF[i]; f++) {
            uintptr_t a = gFrames[i][f];
            Dl_info di;
            if (dladdr((void *)a, &di) && di.dli_fname) {
                const char *img = strrchr(di.dli_fname, '/');
                img = img ? img + 1 : di.dli_fname;
                if (di.dli_sname && di.dli_saddr) {
                    PPLog(@"    %s`%s+%lu", img, di.dli_sname, (unsigned long)(a - (uintptr_t)di.dli_saddr));
                } else {
                    PPLog(@"    %s+0x%lx", img, (unsigned long)(a - (uintptr_t)di.dli_fbase));
                }
            } else {
                PPLog(@"    0x%lx", (unsigned long)a);
            }
        }
    }
    vm_deallocate(mach_task_self(), (vm_address_t)list, cnt * sizeof(thread_t));
}

// ---------- Dart <-> native message tracing ----------
static NSString *PPDescribe(NSString *channel, NSData *msg) {
    NSString *method = @"";
    const uint8_t *b = (const uint8_t *)msg.bytes;
    NSUInteger len = msg.length;
    if (len >= 3 && b[0] == 0x07 && b[1] < 254 && (NSUInteger)b[1] + 2 <= len) {
        NSString *s = [[NSString alloc] initWithBytes:b + 2 length:b[1] encoding:NSUTF8StringEncoding];
        if (s) method = [@" / " stringByAppendingString:s];
    }
    return [NSString stringWithFormat:@"%@%@ (%lu bytes)", channel, method, (unsigned long)len];
}

static void PPHookMessenger(void) {
    if (gMsgHooked) return;
    Class eng = NSClassFromString(@"FlutterEngine");
    if (!eng) { PPLog(@"message tracing: FlutterEngine class missing"); return; }
    SEL sel3 = NSSelectorFromString(@"setMessageHandlerOnChannel:binaryMessageHandler:taskQueue:");
    SEL sel2 = NSSelectorFromString(@"setMessageHandlerOnChannel:binaryMessageHandler:");
    BOOL three = class_getInstanceMethod(eng, sel3) != NULL;
    SEL sel = three ? sel3 : sel2;
    Method m = class_getInstanceMethod(eng, sel);
    if (!m) { PPLog(@"message tracing: no suitable FlutterEngine method found"); return; }
    gMsgHooked = YES;
    IMP orig = method_getImplementation(m);
    IMP nu = imp_implementationWithBlock(^void(id s, NSString *channel, id handler, id queue) {
        id wrapped = handler;
        if (handler) {
            void (^h)(NSData *, void (^)(NSData *)) = handler;
            wrapped = ^(NSData *msg, void (^reply)(NSData *)) {
                NSString *desc = PPDescribe(channel, msg);
                NSString *key;
                @synchronized (gLock) {
                    key = [NSString stringWithFormat:@"%06llu", ++gSeq];
                    gPending[key] = @{@"d": desc, @"t": @(CFAbsoluteTimeGetCurrent() - gStart)};
                    gMsgIn++;
                    gHandlerEnter++;
                }
                PPLog(@"dart->native #%@ %@ handler ENTER queue=%@", key, desc, queue ? NSStringFromClass([queue class]) : @"nil");
                CFAbsoluteTime enter = CFAbsoluteTimeGetCurrent();
                h(msg, ^(NSData *r) {
                    @synchronized (gLock) { [gPending removeObjectForKey:key]; gMsgOut++; gHandlerReply++; }
                    PPLog(@"native->dart #%@ replied after %.2fs", key, CFAbsoluteTimeGetCurrent() - enter);
                    if (reply) reply(r);
                });
                @synchronized (gLock) { gHandlerExit++; }
                PPLog(@"dart->native #%@ %@ handler EXIT after %.2fs", key, desc, CFAbsoluteTimeGetCurrent() - enter);
            };
        }
        if (three) ((void (*)(id, SEL, id, id, id))orig)(s, sel, channel, wrapped, queue);
        else ((void (*)(id, SEL, id, id))orig)(s, sel, channel, wrapped);
    });
    if (!class_addMethod(eng, sel, nu, method_getTypeEncoding(m))) method_setImplementation(m, nu);
    PPLog(@"message tracing installed on %@", NSStringFromSelector(sel));
}

static NSString *PPPendingSummary(NSUInteger maxLines) {
    NSMutableString *out = [NSMutableString string];
    @synchronized (gLock) {
        NSArray *keys = [gPending.allKeys sortedArrayUsingSelector:@selector(compare:)];
        [out appendFormat:@"%lu 條訊息仍在等待回覆", (unsigned long)keys.count];
        NSUInteger shown = 0;
        for (NSString *k in keys) {
            if (shown++ >= maxLines) { [out appendString:@"\n  ..."]; break; }
            NSDictionary *info = gPending[k];
            [out appendFormat:@"\n  #%@ (+%.1fs) %@", k, [info[@"t"] doubleValue], info[@"d"]];
        }
    }
    return out;
}

// ---------- FlutterEngine run / init tracing ----------
static void PPHookEngineLifecycle(void) {
    Class eng = NSClassFromString(@"FlutterEngine");
    if (!eng) return;

    SEL selInit = @selector(initWithName:);
    Method mInit = class_getInstanceMethod(eng, selInit);
    if (mInit) {
        IMP orig = method_getImplementation(mInit);
        IMP nu = imp_implementationWithBlock(^id(id s, NSString *name) {
            id r = ((id (*)(id, SEL, NSString*))orig)(s, selInit, name);
            PPLog(@"FlutterEngine initWithName:%@ -> %p", name, r);
            return r;
        });
        if (!class_addMethod(eng, selInit, nu, method_getTypeEncoding(mInit))) method_setImplementation(mInit, nu);
    }

    SEL selRun = @selector(run);
    Method mRun = class_getInstanceMethod(eng, selRun);
    if (mRun) {
        IMP orig = method_getImplementation(mRun);
        IMP nu = imp_implementationWithBlock(^BOOL(id s) {
            PPLog(@"FlutterEngine run ENTER");
            CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
            BOOL r = ((BOOL (*)(id, SEL))orig)(s, selRun);
            PPLog(@"FlutterEngine run EXIT after %.2fs result=%d", CFAbsoluteTimeGetCurrent() - t, r);
            return r;
        });
        if (!class_addMethod(eng, selRun, nu, method_getTypeEncoding(mRun))) method_setImplementation(mRun, nu);
    }

    SEL selRunEP = NSSelectorFromString(@"runWithEntrypoint:");
    Method mRunEP = class_getInstanceMethod(eng, selRunEP);
    if (mRunEP) {
        IMP orig = method_getImplementation(mRunEP);
        IMP nu = imp_implementationWithBlock(^BOOL(id s, NSString *ep) {
            PPLog(@"FlutterEngine runWithEntrypoint:%@ ENTER", ep);
            CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
            BOOL r = ((BOOL (*)(id, SEL, NSString*))orig)(s, selRunEP, ep);
            PPLog(@"FlutterEngine runWithEntrypoint:%@ EXIT after %.2fs result=%d", ep, CFAbsoluteTimeGetCurrent() - t, r);
            return r;
        });
        if (!class_addMethod(eng, selRunEP, nu, method_getTypeEncoding(mRunEP))) method_setImplementation(mRunEP, nu);
    }
}

// ---------- native -> Dart send tracing (with reply) ----------
static void PPHookSend(void) {
    Class eng = NSClassFromString(@"FlutterEngine");
    if (!eng) return;
    SEL sel = @selector(sendOnChannel:message:binaryReply:);
    Method m = class_getInstanceMethod(eng, sel);
    if (!m) return;
    IMP orig = method_getImplementation(m);
    IMP nu = imp_implementationWithBlock(^(id s, NSString *channel, NSData *msg, id reply) {
        PPLog(@"native->dart(send) %@ (%luB)", channel, (unsigned long)msg.length);
        if (reply) {
            void (^origReply)(NSData *) = reply;
            void (^wrappedReply)(NSData *) = ^(NSData *r) {
                PPLog(@"native->dart(send) %@ reply (%luB)", channel, (unsigned long)r.length);
                origReply(r);
            };
            ((void (*)(id, SEL, NSString*, NSData*, id))orig)(s, sel, channel, msg, wrappedReply);
        } else {
            ((void (*)(id, SEL, NSString*, NSData*, id))orig)(s, sel, channel, msg, nil);
        }
    });
    if (!class_addMethod(eng, sel, nu, method_getTypeEncoding(m))) method_setImplementation(m, nu);
    PPLog(@"send tracing installed on sendOnChannel:message:binaryReply:");
}

// ---------- CADisplayLink control probe ----------
@interface PPDisplayLinkProbe : NSObject
@end
@implementation PPDisplayLinkProbe
- (void)tick:(CADisplayLink *)link {
    gDisplayLinkTicks++;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gDisplayLinkLastTime >= 1.0) {
        NSUInteger delta = gDisplayLinkTicks - gDisplayLinkLastTicks;
        PPLog(@"displayLink control: total=%lu delta=%lu/s", (unsigned long)gDisplayLinkTicks, (unsigned long)delta);
        gDisplayLinkLastTicks = gDisplayLinkTicks;
        gDisplayLinkLastTime = now;
    }
}
@end

static PPDisplayLinkProbe *gDisplayLinkProbe;

static void PPStartDisplayLinkProbe(void) {
    gDisplayLinkProbe = [PPDisplayLinkProbe new];
    gDisplayLink = [CADisplayLink displayLinkWithTarget:gDisplayLinkProbe selector:@selector(tick:)];
    [gDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    gDisplayLinkLastTime = CFAbsoluteTimeGetCurrent();
    PPLog(@"CADisplayLink control probe started");
}

// ---------- Flutter / UIKit hooks ----------
static void PPHook0(Class cls, SEL sel, const char *tag, volatile BOOL *flag) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { PPLog(@"hook skipped (method missing): %s", tag); return; }
    IMP orig = method_getImplementation(m);
    IMP nu = imp_implementationWithBlock(^(id s) {
        PPLog(@"%s", tag);
        if (flag) *flag = YES;
        ((void (*)(id, SEL))orig)(s, sel);
    });
    if (!class_addMethod(cls, sel, nu, method_getTypeEncoding(m))) method_setImplementation(m, nu);
}

static void PPHookBool(Class cls, SEL sel, const char *tag, volatile BOOL *flag) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { PPLog(@"hook skipped (method missing): %s", tag); return; }
    IMP orig = method_getImplementation(m);
    IMP nu = imp_implementationWithBlock(^(id s, BOOL a) {
        PPLog(@"%s", tag);
        if (flag) *flag = YES;
        ((void (*)(id, SEL, BOOL))orig)(s, sel, a);
    });
    if (!class_addMethod(cls, sel, nu, method_getTypeEncoding(m))) method_setImplementation(m, nu);
}

static void PPInstallHooks(void) {
    PPHookMessenger();
    PPHookEngineLifecycle();
    PPHookSend();
    if (gHooked) return;
    Class vc = NSClassFromString(@"FlutterViewController");
    Class eng = NSClassFromString(@"FlutterEngine");
    PPLog(@"FlutterViewController class: %@, FlutterEngine class: %@", vc ? @"found" : @"NOT found", eng ? @"found" : @"NOT found");
    if (!vc) return;
    gHooked = YES;
    PPHook0(vc, @selector(viewDidLoad), "FlutterViewController viewDidLoad", &gSawFlutterLoad);
    PPHookBool(vc, @selector(viewWillAppear:), "FlutterViewController viewWillAppear", NULL);
    PPHookBool(vc, @selector(viewDidAppear:), "FlutterViewController viewDidAppear", &gSawFlutterAppear);
}

static NSString *PPFullLog(void) {
    return [NSString stringWithContentsOfFile:gLogPath encoding:NSUTF8StringEncoding error:nil] ?: @"";
}

static UIWindow *PPKeyWindow(void) {
    UIWindow *win = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if ([sc isKindOfClass:UIWindowScene.class]) {
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (w.isKeyWindow) { win = w; break; }
            }
        }
        if (win) break;
    }
    if (!win) win = UIApplication.sharedApplication.windows.firstObject;
    return win;
}

static UIViewController *PPTopVC(void) {
    UIViewController *vc = PPKeyWindow().rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static NSString *PPEngineState(id engine) {
    if (!engine) return @"nil";
    NSMutableString *s = [NSMutableString string];
    for (NSString *key in @[@"isRunning", @"hasStarted", @"running", @"started", @"isolateId", @"dartIsolateId"]) {
        @try {
            id v = [engine valueForKey:key];
            [s appendFormat:@" %@=%@", key, v];
        } @catch (NSException *e) {}
    }
    return s.length ? s : @"(no accessible state)";
}

static void PPReport(void) {
    PPLog(@"=== REPORT 0.4 ===");
    PPLog(@"flags: didFinishLaunching=%d didBecomeActive=%d window=%d flutterVCLoaded=%d flutterVCAppeared=%d",
          gSawFinish, gSawActive, gSawWindow, gSawFlutterLoad, gSawFlutterAppear);
    PPLogImages("final images");
    unsigned long in, out, enter, exit, reply;
    @synchronized (gLock) { in = gMsgIn; out = gMsgOut; enter = gHandlerEnter; exit = gHandlerExit; reply = gHandlerReply; }
    PPLog(@"messages: dart->native received=%lu, handlerEnter=%lu, handlerExit=%lu, replied=%lu. %@",
          in, enter, exit, reply, PPPendingSummary(40));
    PPLog(@"CADisplayLink control: totalTicks=%lu (delta/s logged above)", (unsigned long)gDisplayLinkTicks);

    // Try to inspect the first FlutterEngine we can find
    Class engClass = NSClassFromString(@"FlutterEngine");
    if (engClass) {
        // Cannot easily enumerate engines; log a note.
        PPLog(@"engine state: (enumeration not available; check run ENTER/EXIT above)");
    }

    PPDumpThreads();
    [UIPasteboard generalPasteboard].string = PPFullLog();

    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *frame = @"未知";
        @try {
            id v = [PPKeyWindow().rootViewController valueForKey:@"displayingFlutterUI"];
            if (v) frame = [v boolValue] ? @"是（畫面已畫出）" : @"否（一直沒畫出第一幀）";
        } @catch (NSException *e) {}
        PPLog(@"Flutter first frame rendered: %@", frame);
        [UIPasteboard generalPasteboard].string = PPFullLog();

        UIViewController *top = PPTopVC();
        if (!top) { PPLog(@"alert skipped: no view controller"); return; }
        NSString *msg = [NSString stringWithFormat:
            @"完整日誌已複製到剪貼簿，貼給 Claude 即可。\n\n"
            @"第一幀已畫出：%@\n"
            @"訊息統計：收到 %lu / 進入 handler %lu / 退出 handler %lu / 已回覆 %lu\n"
            @"CADisplayLink 控制探針總回調：%lu\n"
            @"%@",
            frame, in, enter, exit, reply, (unsigned long)gDisplayLinkTicks, PPPendingSummary(6)];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"PiliProbe 0.4" message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [top presentViewController:a animated:YES completion:nil];
    });
}

static void PPStartWatchdog(void) {
    __block CFAbsoluteTime lastMain = CFAbsoluteTimeGetCurrent();
    dispatch_queue_t q = dispatch_queue_create("piliprobe.watchdog", DISPATCH_QUEUE_SERIAL);
    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, 0);
    dispatch_source_set_event_handler(gTimer, ^{
        dispatch_async(dispatch_get_main_queue(), ^{ lastMain = CFAbsoluteTimeGetCurrent(); });
        PPLog(@"watchdog: main thread last ran %.1fs ago, threads=%d, cpu=%.2fs total",
              CFAbsoluteTimeGetCurrent() - lastMain, PPThreadCount(), PPCpuSeconds());
    });
    dispatch_resume(gTimer);
}

__attribute__((constructor)) static void PPInit(void) {
    @autoreleasepool {
        NSBundle *b = NSBundle.mainBundle;
        NSString *bid = b.bundleIdentifier ?: @"";
        NSString *exe = [b objectForInfoDictionaryKey:@"CFBundleExecutable"] ?: @"";
        NSString *name = [b objectForInfoDictionaryKey:@"CFBundleName"] ?: @"";
        NSString *disp = [b objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"";
        NSString *all = [[NSString stringWithFormat:@"%@ %@ %@ %@", bid, exe, name, disp] lowercaseString];
        if ([all rangeOfString:@"pili"].location == NSNotFound) return;

        gStart = CFAbsoluteTimeGetCurrent();
        gLock = [NSObject new];
        gPending = [NSMutableDictionary dictionary];
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
        gLogPath = [docs stringByAppendingPathComponent:@"piliprobe.log"];
        gLogFD = open(gLogPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0644);

        struct utsname u;
        uname(&u);
        PPLog(@"PiliProbe 0.4.0 started. device=%s iOS=%@ bundle=%@ version=%@(%@) exe=%@",
              u.machine, UIDevice.currentDevice.systemVersion, bid,
              [b objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
              [b objectForInfoDictionaryKey:@"CFBundleVersion"], exe);
        PPLog(@"log file: %@", gLogPath);

        signal(SIGABRT, PPSignal); signal(SIGSEGV, PPSignal); signal(SIGBUS, PPSignal);
        signal(SIGILL, PPSignal);  signal(SIGFPE, PPSignal);  signal(SIGTRAP, PPSignal);
        gPrevExc = NSGetUncaughtExceptionHandler();
        NSSetUncaughtExceptionHandler(PPException);

        NSDictionary *notes = @{
            UIApplicationDidFinishLaunchingNotification: @"UIApplicationDidFinishLaunching",
            UIApplicationWillEnterForegroundNotification: @"UIApplicationWillEnterForeground",
            UIApplicationDidBecomeActiveNotification: @"UIApplicationDidBecomeActive",
            UIApplicationWillResignActiveNotification: @"UIApplicationWillResignActive",
            UIApplicationDidEnterBackgroundNotification: @"UIApplicationDidEnterBackground",
            UIApplicationDidReceiveMemoryWarningNotification: @"MEMORY WARNING",
            UIWindowDidBecomeVisibleNotification: @"UIWindowDidBecomeVisible",
            UIWindowDidBecomeKeyNotification: @"UIWindowDidBecomeKey",
        };
        for (NSString *n in notes) {
            NSString *label = notes[n];
            [[NSNotificationCenter defaultCenter] addObserverForName:n object:nil queue:nil usingBlock:^(NSNotification *note) {
                NSString *extra = @"";
                if ([note.object isKindOfClass:UIWindow.class]) {
                    UIWindow *w = note.object;
                    extra = [NSString stringWithFormat:@" window=%@ rootVC=%@", NSStringFromClass(w.class), NSStringFromClass(w.rootViewController.class)];
                    gSawWindow = YES;
                }
                if ([label hasPrefix:@"UIApplicationDidFinish"]) { gSawFinish = YES; PPInstallHooks(); }
                if ([label hasPrefix:@"UIApplicationDidBecomeActive"]) gSawActive = YES;
                PPLog(@"%@%@", label, extra);
            }];
        }

        PPInstallHooks();
        PPStartDisplayLinkProbe();
        PPStartWatchdog();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ PPReport(); });
    }
}
