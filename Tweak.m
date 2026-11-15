// PiliProbe: logs what a Flutter app (PiliPlus) does while it is stuck on its launch screen.
// Output: Documents/piliprobe.log inside the app container, a copy on the clipboard,
// and an alert after 15 seconds.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <execinfo.h>
#import <signal.h>
#import <sys/utsname.h>
#import <sys/resource.h>
#import <fcntl.h>
#import <unistd.h>

static int gLogFD = -1;
static NSString *gLogPath;
static CFAbsoluteTime gStart;
static volatile BOOL gSawFinish, gSawActive, gSawWindow, gSawFlutterLoad, gSawFlutterAppear;
static dispatch_source_t gTimer;
static void (*gPrevExc)(NSException *);
static BOOL gHooked;

static void PPLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void PPLog(NSString *fmt, ...) {
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

// Hooks that only touch the class itself (never a superclass).
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

static NSString *PPTail(NSUInteger n) {
    NSArray *lines = [PPFullLog() componentsSeparatedByString:@"\n"];
    if (lines.count > n) lines = [lines subarrayWithRange:NSMakeRange(lines.count - n, n)];
    return [lines componentsJoinedByString:@"\n"];
}

static UIViewController *PPTopVC(void) {
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
    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void PPReport(void) {
    PPLog(@"=== REPORT === didFinishLaunching=%d didBecomeActive=%d window=%d flutterVCLoaded=%d flutterVCAppeared=%d",
          gSawFinish, gSawActive, gSawWindow, gSawFlutterLoad, gSawFlutterAppear);
    PPLogImages("final images");
    NSString *full = PPFullLog();
    [UIPasteboard generalPasteboard].string = full;
    NSString *msg = [NSString stringWithFormat:@"完整日誌已複製到剪貼簿，直接貼給 Claude 即可。\n\n%@", PPTail(16)];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = PPTopVC();
        if (!top) { PPLog(@"alert skipped: no view controller"); return; }
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"PiliProbe" message:msg
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
        if ([all rangeOfString:@"pili"].location == NSNotFound) return; // only touch PiliPlus

        gStart = CFAbsoluteTimeGetCurrent();
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
        gLogPath = [docs stringByAppendingPathComponent:@"piliprobe.log"];
        gLogFD = open(gLogPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0644);

        struct utsname u;
        uname(&u);
        PPLog(@"PiliProbe 0.1 started. device=%s iOS=%@ bundle=%@ version=%@(%@) exe=%@",
              u.machine, UIDevice.currentDevice.systemVersion, bid,
              [b objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
              [b objectForInfoDictionaryKey:@"CFBundleVersion"], exe);
        PPLog(@"log file: %@", gLogPath);

        NSDictionary *fs = [NSFileManager.defaultManager attributesOfFileSystemForPath:NSHomeDirectory() error:nil];
        PPLog(@"free disk: %.1f GB", [fs[NSFileSystemFreeSize] doubleValue] / 1e9);

        NSString *fw = b.privateFrameworksPath;
        NSFileManager *fm = NSFileManager.defaultManager;
        NSArray *items = [fm contentsOfDirectoryAtPath:fw error:nil];
        PPLog(@"Frameworks (%lu): %@", (unsigned long)items.count, [items componentsJoinedByString:@", "]);
        PPLog(@"Flutter binary exists: %d", [fm fileExistsAtPath:[fw stringByAppendingPathComponent:@"Flutter.framework/Flutter"]]);
        PPLog(@"App.framework/App exists: %d", [fm fileExistsAtPath:[fw stringByAppendingPathComponent:@"App.framework/App"]]);
        PPLog(@"flutter_assets exists: %d", [fm fileExistsAtPath:[fw stringByAppendingPathComponent:@"App.framework/flutter_assets"]]);
        PPLog(@"debug-build marker (kernel_blob.bin) exists: %d (1 would mean a debug build, which cannot run from the home screen)",
              [fm fileExistsAtPath:[fw stringByAppendingPathComponent:@"App.framework/flutter_assets/kernel_blob.bin"]]);
        PPLogImages("startup images");

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
        PPStartWatchdog();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ PPReport(); });
    }
}
