// PiliProbe 0.5.0  —— 一次性采集版（装一次就能定案）
//
// 已确认的事实（v1/v2/v3 日志）：
//   +0.24s  Dart 最后两条消息：flutter/platform(JSON System.initializationComplete，已回覆)、
//           flutter/isolate(isolates/<id>，15.7 秒仍未回覆)；此后 15.7 秒无任何 Dart 消息。
//   +1.20s 起所有线程 dump 都没有 io.flutter.<n>.ui，而 1.raster / 1.io / io.worker.1-3 /
//           dart:io EventHandler 全在；14 秒 CPU 只涨 0.08s；stderr+stdout 已重定向却零输出；
//           Metal 设备正常（Apple A15 GPU）；一个插件通道都没注册。
//
// 待判定的核心分歧：
//   H3 = Dart 还活着、卡在某个原生/FFI 调用上（ui 线程应该在，只是 waiting）
//   H4 = ui 线程已经静默退出（进程和引擎其他线程都还活着）
//
// 0.5 的采集手段（一次运行全部拿到）：
//   1. 20ms 一次的「命名线程集合变化」日志：每一增一减都记，并在变化瞬间抓一次全线程栈。
//      → 直接定死 H3/H4，并给出消失的精确时刻。
//   2. 50ms 一次的 PC 采样：ui / raster / io 以及任何「非 libsystem 的无名线程」当前所在函数。
//      → 给出断气前最后位置；符号带 image+偏移，可离线还原。
//   3. 0.15~6.0 秒之间 14 次重点线程全栈。
//   4. 记录每个注册上来的通道名（插件注册证据）。
//   5. 钩 FlutterEngine 的 run / runWithEntrypoint: / runWithEntrypoint:libraryURI: / destroyContext，
//      统计引擎启动次数与被销毁。
//   6. Metal 探测、Impeller 强制开关（Documents 空文件）、视图树、非系统 dylib 清单。
//
// 日志：App 的 Documents/piliprobe.log，15.5 秒后弹窗并复制全文到剪贴板。

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
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
#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#endif

static int gLogFD = -1;
static NSString *gLogPath;
static CFAbsoluteTime gStart;
static dispatch_queue_t gProbeQ;
static dispatch_source_t gTickTimer, gWatchTimer, gSampleTimer;
static volatile BOOL gSawFinish, gSawActive, gSawWindow, gSawFlutterLoad, gSawFlutterAppear;
static void (*gPrevExc)(NSException *);
static BOOL gHookedVC, gHookedMsg, gHookedSend, gHookedBundle, gHookedEngine;
static volatile unsigned gLines;

static NSObject *gLock;
static NSMutableDictionary *gPending;
static NSMutableDictionary *gChanStat;
static NSMutableArray *gRegistered;
static uint64_t gSeq;
static unsigned long gMsgIn, gMsgOut;

static int gImpellerMode;
static volatile BOOL gImpellerRead;

static int gThreadCount;
static volatile BOOL gSawUIThread;
static volatile BOOL gSeenUI, gUIGoneLogged;
static volatile double gLastUISeen;
static volatile int gEngineRuns, gEngineDestroyed;
static NSArray *gNamedSig;              // 上一次的命名线程集合
static volatile int gPhase;             // 0 = 前 3 秒高频

static void PPLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static NSString *PPMethodName(NSData *msg);
static double PPCpuSeconds(void);
static void PPThreadsFiltered(const char *label, BOOL onlyImportant);
static NSString *PPShortSym(uintptr_t a);
static NSString *PPChanSummary(void);
static void PPLogViewTree(UIView *v, int depth);

// ---------------------------------------------------------------- 日志

static void PPLog(NSString *fmt, ...) {
    if (gLines++ > 30000) return;
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
    PPLog(@"!!! UNCAUGHT OBJC EXCEPTION %@: %@\n%@", e.name, e.reason, e.callStackSymbols);
    if (gPrevExc) gPrevExc(e);
}

static double PPCpuSeconds(void) {
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    return ru.ru_utime.tv_sec + ru.ru_utime.tv_usec / 1e6
         + ru.ru_stime.tv_sec + ru.ru_stime.tv_usec / 1e6;
}

static char PPStateChar(integer_t s) {
    switch (s) {
        case TH_STATE_RUNNING: return 'r';
        case TH_STATE_STOPPED: return 's';
        case TH_STATE_WAITING: return 'w';
        case TH_STATE_UNINTERRUPTIBLE: return 'u';
        case TH_STATE_HALTED: return 'h';
        default: return '?';
    }
}

static const char *PPStateName(integer_t s) {
    switch (s) {
        case TH_STATE_RUNNING: return "running";
        case TH_STATE_STOPPED: return "stopped";
        case TH_STATE_WAITING: return "waiting";
        case TH_STATE_UNINTERRUPTIBLE: return "uninterruptible";
        case TH_STATE_HALTED: return "halted";
        default: return "?";
    }
}

// 只认 io.flutter.<n>.ui —— 0.3 用 strstr(".ui") 把 com.apple.uikit 也认成 ui 线程了。
static BOOL PPIsUIThread(const char *nm) {
    return nm && strncmp(nm, "io.flutter.", 11) == 0 && strstr(nm, ".ui") != NULL;
}
static BOOL PPIsRasterThread(const char *nm) {
    return nm && strncmp(nm, "io.flutter.", 11) == 0 && strstr(nm, ".raster") != NULL;
}
static BOOL PPIsIOThread(const char *nm) {
    return nm && strncmp(nm, "io.flutter.", 11) == 0 && strstr(nm, ".io") != NULL;
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
    PPLog(@"%s: %u images loaded, %lu from the app bundle", label, n, (unsigned long)names.count);
    PPLog(@"  app-bundle images: %@", [names componentsJoinedByString:@", "]);
}

// 非系统镜像 = 越狱注入的东西（roothide / ElleKit / 本插件）
static void PPLogForeignImages(void) {
    uint32_t n = _dyld_image_count();
    NSMutableArray *out = [NSMutableArray array];
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (!nm) continue;
        if (strncmp(nm, "/System/", 8) == 0) continue;
        if (strncmp(nm, "/usr/lib/", 9) == 0) continue;
        if (strstr(nm, ".app/")) continue;
        [out addObject:[NSString stringWithUTF8String:nm]];
    }
    PPLog(@"non-system images (%lu): %@", (unsigned long)out.count, [out componentsJoinedByString:@", "]);
}

// ---------------------------------------------------------------- 线程

#define PP_MAXT 48
#define PP_MAXF 16
static uintptr_t gFrames[PP_MAXT][PP_MAXF];
static int gNF[PP_MAXT];
static char gTName[PP_MAXT][64];
static double gTCpu[PP_MAXT];
static integer_t gTState[PP_MAXT];

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

// 优先给「image+0x偏移」，这样离线也能对着 dSYM/符号还原；有干净符号时一并给出。
static NSString *PPShortSym(uintptr_t a) {
    if (!a) return @"?";
    Dl_info di;
    if (dladdr((void *)a, &di) && di.dli_fname) {
        const char *img = strrchr(di.dli_fname, '/');
        img = img ? img + 1 : di.dli_fname;
        uintptr_t base = (uintptr_t)di.dli_fbase;
        unsigned long off = (unsigned long)(a - base);
        if (di.dli_sname && di.dli_saddr) {
            unsigned long delta = (unsigned long)(a - (uintptr_t)di.dli_saddr);
            if (delta < 0x2000) {
                return [NSString stringWithFormat:@"%s`%s+%lu", img, di.dli_sname, delta];
            }
        }
        return [NSString stringWithFormat:@"%s+0x%lx", img, off];
    }
    return [NSString stringWithFormat:@"0x%lx", (unsigned long)a];
}

static BOOL PPIsIdleSym(NSString *s) {
    return [s hasPrefix:@"libsystem_kernel"] || [s hasPrefix:@"libsystem_pthread"]
        || [s hasPrefix:@"libdispatch"] || [s isEqualToString:@"?"];
}

static uintptr_t PPGetPC(thread_t t) {
    arm_thread_state64_t st;
    mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(t, ARM_THREAD_STATE64, (thread_state_t)&st, &sc) != KERN_SUCCESS) return 0;
    return PPStrip(arm_thread_state64_get_pc(st));
}

// 把当前所有「有名字」的线程名收集起来（无名线程是 GCD 的，变化太频繁，不参与比较）
static NSArray *PPNamedThreads(mach_msg_type_number_t *outCnt, thread_act_array_t *outList) {
    thread_act_array_t list = NULL;
    mach_msg_type_number_t cnt = 0;
    if (task_threads(mach_task_self(), &list, &cnt) != KERN_SUCCESS) return nil;
    NSMutableArray *names = [NSMutableArray array];
    for (mach_msg_type_number_t i = 0; i < cnt; i++) {
        char nm[64];
        nm[0] = 0;
        pthread_t pt = pthread_from_mach_thread_np(list[i]);
        if (pt) pthread_getname_np(pt, nm, sizeof nm);
        if (nm[0]) [names addObject:[NSString stringWithUTF8String:nm]];
    }
    [names sortUsingSelector:@selector(compare:)];
    if (outCnt) *outCnt = cnt;
    if (outList) *outList = list;
    else vm_deallocate(mach_task_self(), (vm_address_t)list, cnt * sizeof(thread_t));
    return names;
}

static void PPTick(void) {
    thread_act_array_t list = NULL;
    mach_msg_type_number_t cnt = 0;
    if (task_threads(mach_task_self(), &list, &cnt) != KERN_SUCCESS) return;
    thread_t me = mach_thread_self();
    NSMutableString *sb = [NSMutableString string];
    BOOL ui = NO;
    int shown = 0;
    for (mach_msg_type_number_t i = 0; i < cnt && shown < 26; i++) {
        char nm[64];
        nm[0] = 0;
        pthread_t pt = pthread_from_mach_thread_np(list[i]);
        if (pt) pthread_getname_np(pt, nm, sizeof nm);
        if (!nm[0]) { nm[0] = '-'; nm[1] = 0; }
        thread_basic_info_data_t bi;
        mach_msg_type_number_t bic = THREAD_BASIC_INFO_COUNT;
        double c = -1;
        char st = '?';
        if (thread_info(list[i], THREAD_BASIC_INFO, (thread_info_t)&bi, &bic) == KERN_SUCCESS) {
            c = bi.user_time.seconds + bi.user_time.microseconds / 1e6
              + bi.system_time.seconds + bi.system_time.microseconds / 1e6;
            st = PPStateChar(bi.run_state);
        }
        if (PPIsUIThread(nm)) ui = YES;
        if (list[i] == me) [sb appendFormat:@"{probe}%.2f%c ", c, st];
        else [sb appendFormat:@"%s/%.2f%c ", nm, c, st];
        shown++;
    }
    gThreadCount = (int)cnt;
    gSawUIThread = ui;
    PPLog(@"tick threads=%u ui-thread=%s cpu=%.2fs | %@",
          (unsigned)cnt, ui ? "YES" : "NO", PPCpuSeconds(), sb);
    mach_port_deallocate(mach_task_self(), me);
    vm_deallocate(mach_task_self(), (vm_address_t)list, cnt * sizeof(thread_t));
}

// 命名线程集合变化监听：一增一减都记，变化瞬间抓一次全线程栈。这是判定 H3/H4 的关键。
static void PPWatch(void) {
    thread_act_array_t list = NULL;
    mach_msg_type_number_t cnt = 0;
    NSArray *cur = PPNamedThreads(&cnt, &list);
    if (!cur) return;
    vm_deallocate(mach_task_self(), (vm_address_t)list, cnt * sizeof(thread_t));

    if (!gNamedSig) {
        gNamedSig = cur;
        PPLog(@"named threads baseline (total=%u unnamed+ named): %@", (unsigned)cnt,
              [cur componentsJoinedByString:@", "]);
        return;
    }
    if ([cur isEqualToArray:gNamedSig]) return;

    NSMutableSet *before = [NSMutableSet setWithArray:gNamedSig];
    NSMutableSet *after = [NSMutableSet setWithArray:cur];
    NSMutableSet *added = [NSMutableSet setWithSet:after];
    [added minusSet:before];
    NSMutableSet *removed = [NSMutableSet setWithSet:before];
    [removed minusSet:after];

    NSMutableString *d = [NSMutableString string];
    if (added.count) [d appendFormat:@" | 新增: %@", [[added allObjects] componentsJoinedByString:@", "]];
    if (removed.count) [d appendFormat:@" | 消失: %@", [[removed allObjects] componentsJoinedByString:@", "]];
    PPLog(@"!!! 命名线程变化 total=%u%@", (unsigned)cnt, d);
    gNamedSig = cur;

    if (removed.count || added.count) {
        char lbl[64];
        snprintf(lbl, sizeof lbl, "on-change total=%u", (unsigned)cnt);
        PPThreadsFiltered(lbl, NO);
    }
}

// PC 采样：只看寄存器，不挂起线程。无名但不在 libsystem 里的线程也会被抓出来（防漏判）。
static void PPSample(void) {
    thread_act_array_t list = NULL;
    mach_msg_type_number_t cnt = 0;
    if (task_threads(mach_task_self(), &list, &cnt) != KERN_SUCCESS) return;
    uintptr_t uiPC = 0, rasterPC = 0, ioPC = 0;
    BOOL ui = NO;
    NSMutableString *anon = [NSMutableString string];
    for (mach_msg_type_number_t i = 0; i < cnt; i++) {
        char nm[64];
        nm[0] = 0;
        pthread_t pt = pthread_from_mach_thread_np(list[i]);
        if (pt) pthread_getname_np(pt, nm, sizeof nm);
        if (PPIsUIThread(nm)) { ui = YES; if (!uiPC) uiPC = PPGetPC(list[i]); }
        else if (PPIsRasterThread(nm)) { if (!rasterPC) rasterPC = PPGetPC(list[i]); }
        else if (PPIsIOThread(nm)) { if (!ioPC) ioPC = PPGetPC(list[i]); }
        else if (!nm[0]) {
            uintptr_t pc = PPGetPC(list[i]);
            NSString *sym = PPShortSym(pc);
            if (!PPIsIdleSym(sym)) [anon appendFormat:@" anon#%u=%@", (unsigned)i, sym];
        }
    }
    double now = CFAbsoluteTimeGetCurrent() - gStart;
    PPLog(@"sample t=%.2f thr=%u cpu=%.2f ui=%@ raster=%@ io=%@%@",
          now, (unsigned)cnt, PPCpuSeconds(),
          ui ? PPShortSym(uiPC) : @"ABSENT",
          rasterPC ? PPShortSym(rasterPC) : @"-",
          ioPC ? PPShortSym(ioPC) : @"-",
          anon);
    if (ui) {
        gSeenUI = YES;
        gLastUISeen = now;
    } else if (gSeenUI && !gUIGoneLogged) {
        gUIGoneLogged = YES;
        PPLog(@"!!! ui 线程消失：最后见到是 +%.2fs", gLastUISeen);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)list, cnt * sizeof(thread_t));
}

static void PPThreadsFiltered(const char *label, BOOL onlyImportant) {
    thread_act_array_t list = NULL;
    mach_msg_type_number_t cnt = 0;
    if (task_threads(mach_task_self(), &list, &cnt) != KERN_SUCCESS) return;
    if (cnt > PP_MAXT) cnt = PP_MAXT;
    thread_t me = mach_thread_self();
    BOOL ui = NO;

    for (mach_msg_type_number_t i = 0; i < cnt; i++) {
        gTName[i][0] = 0;
        gNF[i] = 0;
        gTCpu[i] = -1;
        gTState[i] = -1;
        pthread_t pt = pthread_from_mach_thread_np(list[i]);
        if (pt) pthread_getname_np(pt, gTName[i], sizeof gTName[i]);
        if (PPIsUIThread(gTName[i])) ui = YES;
        thread_basic_info_data_t bi;
        mach_msg_type_number_t bic = THREAD_BASIC_INFO_COUNT;
        if (thread_info(list[i], THREAD_BASIC_INFO, (thread_info_t)&bi, &bic) == KERN_SUCCESS) {
            gTCpu[i] = bi.user_time.seconds + bi.user_time.microseconds / 1e6
                     + bi.system_time.seconds + bi.system_time.microseconds / 1e6;
            gTState[i] = bi.run_state;
        }
    }

    for (mach_msg_type_number_t i = 0; i < cnt; i++) {
        if (list[i] == me) continue;
        BOOL want = YES;
        if (onlyImportant) {
            want = PPIsUIThread(gTName[i]) || PPIsRasterThread(gTName[i])
                || PPIsIOThread(gTName[i]) || gTName[i][0] == 0;
        }
        if (!want) continue;
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

    gThreadCount = (int)cnt;
    gSawUIThread = ui;
    PPLog(@"--- dump [%s] threads=%u ui-thread=%s cpu=%.2fs ---",
          label, (unsigned)cnt, ui ? "YES" : "NO", PPCpuSeconds());
    for (mach_msg_type_number_t i = 0; i < cnt; i++) {
        if (onlyImportant && gNF[i] == 0) continue;
        PPLog(@"thread %u name='%s' state=%s cpu=%.2fs%s", i, gTName[i], PPStateName(gTState[i]),
              gTCpu[i], list[i] == me ? " (probe)" : "");
        for (int f = 0; f < gNF[i]; f++) {
            PPLog(@"    %@", PPShortSym(gFrames[i][f]));
        }
    }
    mach_port_deallocate(mach_task_self(), me);
    vm_deallocate(mach_task_self(), (vm_address_t)list, cnt * sizeof(thread_t));
}

// ---------------------------------------------------------------- 通道消息

static NSString *PPMethodName(NSData *msg) {
    if (!msg || msg.length < 3) return nil;
    const uint8_t *b = (const uint8_t *)msg.bytes;
    NSUInteger len = msg.length;
    if (b[0] == 0x07 && b[1] < 254 && (NSUInteger)b[1] + 2 <= len) {
        NSString *s = [[NSString alloc] initWithBytes:b + 2 length:b[1] encoding:NSUTF8StringEncoding];
        if (s.length) return s;
    }
    return nil;
}

static NSString *PPHex(NSData *d, NSUInteger max) {
    if (!d.length) return @"-";
    const uint8_t *b = (const uint8_t *)d.bytes;
    NSUInteger n = d.length < max ? d.length : max;
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = 0; i < n; i++) [s appendFormat:@"%02x", b[i]];
    if (d.length > max) [s appendString:@"..."];
    return s;
}

static NSString *PPPrintable(NSData *d) {
    if (!d.length) return @"-";
    const uint8_t *b = (const uint8_t *)d.bytes;
    NSUInteger n = d.length < 120 ? d.length : 120;
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = 0; i < n; i++) {
        uint8_t c = b[i];
        if (c >= 32 && c < 127) [s appendFormat:@"%c", c];
        else [s appendString:@"."];
    }
    return s;
}

static NSString *PPDescribe(NSString *channel, NSData *msg) {
    NSString *m = PPMethodName(msg);
    return [NSString stringWithFormat:@"%@%@ (%luB) hex=%@ ascii=%@",
            channel, m ? [@" / " stringByAppendingString:m] : @"",
            (unsigned long)msg.length, PPHex(msg, 48), PPPrintable(msg)];
}

static NSString *PPNoteIn(NSString *channel, NSData *msg) {
    NSString *ch = channel.length ? channel : @"?";
    NSString *desc = PPDescribe(ch, msg);
    NSString *key;
    @synchronized (gLock) {
        key = [NSString stringWithFormat:@"%06llu", ++gSeq];
        gPending[key] = @{@"c": ch, @"d": desc, @"t": @(CFAbsoluteTimeGetCurrent() - gStart)};
        gMsgIn++;
        NSArray *old = gChanStat[ch];
        gChanStat[ch] = old ? @[@([old[0] unsignedLongValue] + 1), old[1]] : @[@1, @0];
    }
    return key;
}

static void PPNoteOut(NSString *channel, NSString *key) {
    NSString *ch = channel.length ? channel : @"?";
    @synchronized (gLock) {
        [gPending removeObjectForKey:key];
        gMsgOut++;
        NSArray *old = gChanStat[ch];
        gChanStat[ch] = old ? @[old[0], @([old[1] unsignedLongValue] + 1)] : @[@0, @1];
    }
}

static id PPWrapHandler(NSString *channel, id handler) {
    if (!handler) return nil;
    NSString *ch = [channel copy];
    void (^h)(NSData *, void (^)(NSData *)) = (void (^)(NSData *, void (^)(NSData *)))handler;
    void (^wrapper)(NSData *, void (^)(NSData *)) = ^(NSData *msg, void (^reply)(NSData *)) {
        NSString *key = PPNoteIn(ch, msg);
        PPLog(@"dart->native #%@ %@", key, PPDescribe(ch, msg));
        h(msg, ^(NSData *r) {
            PPNoteOut(ch, key);
            PPLog(@"native->dart #%@ replied (%@)", key, ch);
            if (reply) reply(r);
        });
    };
    return (id)[wrapper copy];
}

static void PPHookMessenger(void) {
    if (gHookedMsg) return;
    Class eng = NSClassFromString(@"FlutterEngine");
    if (!eng) { PPLog(@"message tracing: FlutterEngine class missing (will retry)"); return; }
    SEL sel3 = NSSelectorFromString(@"setMessageHandlerOnChannel:binaryMessageHandler:taskQueue:");
    BOOL three = class_getInstanceMethod(eng, sel3) != NULL;
    SEL sel = three ? sel3 : NSSelectorFromString(@"setMessageHandlerOnChannel:binaryMessageHandler:");
    Method m = class_getInstanceMethod(eng, sel);
    if (!m) { PPLog(@"message tracing: no suitable FlutterEngine method found"); return; }
    IMP orig = method_getImplementation(m);
    const char *enc = method_getTypeEncoding(m);
    IMP nu = nil;
    if (three) {
        nu = imp_implementationWithBlock(^(id s, NSString *channel, id handler, id queue) {
            @synchronized (gLock) { [gRegistered addObject:channel.length ? channel : @"?"]; }
            PPLog(@"register handler: %@ (handler=%@)", channel, handler ? @"yes" : @"nil");
            id w = PPWrapHandler(channel, handler);
            void (*f)(id, SEL, id, id, id) = (void (*)(id, SEL, id, id, id))orig;
            f(s, sel, channel, w, queue);
        });
    } else {
        nu = imp_implementationWithBlock(^(id s, NSString *channel, id handler) {
            @synchronized (gLock) { [gRegistered addObject:channel.length ? channel : @"?"]; }
            PPLog(@"register handler: %@ (handler=%@)", channel, handler ? @"yes" : @"nil");
            id w = PPWrapHandler(channel, handler);
            void (*f)(id, SEL, id, id) = (void (*)(id, SEL, id, id))orig;
            f(s, sel, channel, w);
        });
    }
    if (!class_addMethod(eng, sel, nu, enc)) method_setImplementation(m, nu);
    gHookedMsg = YES;
    PPLog(@"message tracing installed on %@", NSStringFromSelector(sel));
}

static void PPHookSendOnChannel(void) {
    if (gHookedSend) return;
    Class eng = NSClassFromString(@"FlutterEngine");
    if (!eng) return;
    SEL s2 = NSSelectorFromString(@"sendOnChannel:message:binaryReply:");
    Method m2 = class_getInstanceMethod(eng, s2);
    if (m2) {
        IMP orig = method_getImplementation(m2);
        const char *enc = method_getTypeEncoding(m2);
        IMP nu = imp_implementationWithBlock(^(id s, NSString *channel, NSData *msg, id reply) {
            NSString *meth = PPMethodName(msg);
            PPLog(@"native->dart(send) %@%@ (%luB)", channel,
                  meth ? [@" / " stringByAppendingString:meth] : @"",
                  (unsigned long)msg.length);
            void (*f)(id, SEL, id, id, id) = (void (*)(id, SEL, id, id, id))orig;
            f(s, s2, channel, msg, reply);
        });
        if (!class_addMethod(eng, s2, nu, enc)) method_setImplementation(m2, nu);
        PPLog(@"send tracing installed on sendOnChannel:message:binaryReply:");
    } else {
        PPLog(@"send tracing: sendOnChannel:message:binaryReply: missing");
    }
    gHookedSend = YES;
}

// ---------------------------------------------------------------- Impeller / 引擎生命周期

static void PPHookBundle(void) {
    if (gHookedBundle) return;
    if (gImpellerMode == 0) return;
    Method m = class_getInstanceMethod([NSBundle class], @selector(objectForInfoDictionaryKey:));
    if (!m) { PPLog(@"impeller override: NSBundle method missing"); return; }
    IMP orig = method_getImplementation(m);
    const char *enc = method_getTypeEncoding(m);
    IMP nu = imp_implementationWithBlock(^id(id b, NSString *key) {
        id v = ((id (*)(id, SEL, id))orig)(b, @selector(objectForInfoDictionaryKey:), key);
        if ([key isEqualToString:@"FLTEnableImpeller"]) {
            if (!gImpellerRead) {
                gImpellerRead = YES;
                PPLog(@"app read FLTEnableImpeller (original=%@) -> forcing %@",
                      v ?: @"nil", gImpellerMode < 0 ? @"NO" : @"YES");
            }
            return (gImpellerMode < 0 ? (id)@NO : (id)@YES);
        }
        return v;
    });
    if (!class_addMethod([NSBundle class], @selector(objectForInfoDictionaryKey:), nu, enc)) {
        method_setImplementation(m, nu);
    }
    gHookedBundle = YES;
    PPLog(@"impeller override installed (mode=%d)", gImpellerMode);
}

static void PPHookEngineLifecycle(void) {
    if (gHookedEngine) return;
    Class eng = NSClassFromString(@"FlutterEngine");
    if (!eng) return;

    SEL sRun = NSSelectorFromString(@"run");
    Method m = class_getInstanceMethod(eng, sRun);
    if (m) {
        IMP orig = method_getImplementation(m);
        const char *enc = method_getTypeEncoding(m);
        IMP nu = imp_implementationWithBlock(^(id s) {
            gEngineRuns++;
            PPLog(@"!!! FlutterEngine run  (第 %d 次)", gEngineRuns);
            ((void (*)(id, SEL))orig)(s, sRun);
        });
        if (!class_addMethod(eng, sRun, nu, enc)) method_setImplementation(m, nu);
    }

    SEL sRun1 = NSSelectorFromString(@"runWithEntrypoint:");
    Method m1 = class_getInstanceMethod(eng, sRun1);
    if (m1) {
        IMP orig = method_getImplementation(m1);
        const char *enc = method_getTypeEncoding(m1);
        IMP nu = imp_implementationWithBlock(^(id s, id entry) {
            gEngineRuns++;
            PPLog(@"!!! FlutterEngine runWithEntrypoint: %@ (第 %d 次)", entry, gEngineRuns);
            ((void (*)(id, SEL, id))orig)(s, sRun1, entry);
        });
        if (!class_addMethod(eng, sRun1, nu, enc)) method_setImplementation(m1, nu);
    }

    SEL sRun2 = NSSelectorFromString(@"runWithEntrypoint:libraryURI:");
    Method m2 = class_getInstanceMethod(eng, sRun2);
    if (m2) {
        IMP orig = method_getImplementation(m2);
        const char *enc = method_getTypeEncoding(m2);
        IMP nu = imp_implementationWithBlock(^(id s, id entry, id uri) {
            gEngineRuns++;
            PPLog(@"!!! FlutterEngine runWithEntrypoint:%@ libraryURI:%@ (第 %d 次)", entry, uri, gEngineRuns);
            ((void (*)(id, SEL, id, id))orig)(s, sRun2, entry, uri);
        });
        if (!class_addMethod(eng, sRun2, nu, enc)) method_setImplementation(m2, nu);
    }

    SEL sDestroy = NSSelectorFromString(@"destroyContext");
    Method md = class_getInstanceMethod(eng, sDestroy);
    if (md) {
        IMP orig = method_getImplementation(md);
        const char *enc = method_getTypeEncoding(md);
        IMP nu = imp_implementationWithBlock(^(id s) {
            gEngineDestroyed++;
            PPLog(@"!!! -[FlutterEngine destroyContext] called (第 %d 次) <-- 引擎被主动拆掉", gEngineDestroyed);
            ((void (*)(id, SEL))orig)(s, sDestroy);
        });
        if (!class_addMethod(eng, sDestroy, nu, enc)) method_setImplementation(md, nu);
    }

    gHookedEngine = YES;
    PPLog(@"engine lifecycle hooks installed (run=%d run1=%d run2=%d destroy=%d)",
          m != NULL, m1 != NULL, m2 != NULL, md != NULL);
}

static void PPMetalCheck(void) {
    void *h = dlopen("/System/Library/Frameworks/Metal.framework/Metal", RTLD_LAZY);
    if (!h) { PPLog(@"metal: dlopen failed: %s", dlerror()); return; }
    id (*create)(void) = (id (*)(void))dlsym(h, "MTLCreateSystemDefaultDevice");
    if (!create) { PPLog(@"metal: MTLCreateSystemDefaultDevice missing"); return; }
    id dev = create();
    if (!dev) { PPLog(@"metal: MTLCreateSystemDefaultDevice -> NIL  <<< GPU 不可用"); return; }
    NSString *nm = nil;
    @try { nm = [dev valueForKey:@"name"]; } @catch (NSException *e) {}
    PPLog(@"metal: device OK (%@) %@", nm ?: @"?", NSStringFromClass([dev class]));
}

static void PPHook0(Class cls, SEL sel, const char *tag, volatile BOOL *flag) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { PPLog(@"hook skipped (method missing): %s", tag); return; }
    IMP orig = method_getImplementation(m);
    const char *enc = method_getTypeEncoding(m);
    IMP nu = imp_implementationWithBlock(^(id s) {
        PPLog(@"%s", tag);
        if (flag) *flag = YES;
        ((void (*)(id, SEL))orig)(s, sel);
    });
    if (!class_addMethod(cls, sel, nu, enc)) method_setImplementation(m, nu);
}

static void PPHookBool(Class cls, SEL sel, const char *tag, volatile BOOL *flag) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { PPLog(@"hook skipped (method missing): %s", tag); return; }
    IMP orig = method_getImplementation(m);
    const char *enc = method_getTypeEncoding(m);
    IMP nu = imp_implementationWithBlock(^(id s, BOOL a) {
        PPLog(@"%s (%d)", tag, (int)a);
        if (flag) *flag = YES;
        ((void (*)(id, SEL, BOOL))orig)(s, sel, a);
    });
    if (!class_addMethod(cls, sel, nu, enc)) method_setImplementation(m, nu);
}

static void PPInstallHooks(void) {
    PPHookMessenger();
    PPHookSendOnChannel();
    PPHookEngineLifecycle();
    if (gHookedVC) return;
    Class vc = NSClassFromString(@"FlutterViewController");
    Class eng = NSClassFromString(@"FlutterEngine");
    PPLog(@"classes: FlutterViewController=%@ FlutterEngine=%@ FlutterView=%@",
          vc ? @"found" : @"NOT found", eng ? @"found" : @"NOT found",
          NSClassFromString(@"FlutterView") ? @"found" : @"NOT found");
    if (!vc) return;
    gHookedVC = YES;
    PPHook0(vc, @selector(viewDidLoad), "FlutterViewController viewDidLoad", &gSawFlutterLoad);
    PPHookBool(vc, @selector(viewWillAppear:), "FlutterViewController viewWillAppear", NULL);
    PPHookBool(vc, @selector(viewDidAppear:), "FlutterViewController viewDidAppear", &gSawFlutterAppear);
}

// ---------------------------------------------------------------- 报表

static NSString *PPFullLog(void) {
    NSString *s = [NSString stringWithContentsOfFile:gLogPath encoding:NSUTF8StringEncoding error:nil];
    return s ?: @"";
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

static void PPLogViewTree(UIView *v, int depth) {
    if (!v || depth > 4) return;
    NSString *pad = [@"" stringByPaddingToLength:(NSUInteger)(depth * 2) withString:@" " startingAtIndex:0];
    PPLog(@"%@view[%d] %@ frame=%@ hidden=%d alpha=%.2f subviews=%lu",
          pad, depth, NSStringFromClass(v.class), NSStringFromCGRect(v.frame),
          (int)v.hidden, v.alpha, (unsigned long)v.subviews.count);
    for (UIView *sub in v.subviews) PPLogViewTree(sub, depth + 1);
}

static NSString *PPChanSummary(void) {
    NSMutableString *out = [NSMutableString string];
    @synchronized (gLock) {
        [out appendFormat:@"%lu 条 dart->native，%lu 条已回覆", gMsgIn, gMsgOut];
        [out appendFormat:@"\n注册过的通道 %lu 个: %@", (unsigned long)gRegistered.count,
         [gRegistered componentsJoinedByString:@", "]];
        if (gChanStat.count) {
            [out appendString:@"\n按通道统计:"];
            NSArray *keys = [gChanStat.allKeys sortedArrayUsingSelector:@selector(compare:)];
            for (NSString *k in keys) {
                NSArray *v = gChanStat[k];
                [out appendFormat:@"\n  %@ : 收 %@ / 回 %@", k, v[0], v[1]];
            }
        }
        if (gPending.count) {
            [out appendFormat:@"\n仍在等待回覆 %lu 条:", (unsigned long)gPending.count];
            NSArray *pk = [gPending.allKeys sortedArrayUsingSelector:@selector(compare:)];
            NSUInteger shown = 0;
            for (NSString *k in pk) {
                if (shown++ >= 12) { [out appendString:@"\n  ..."]; break; }
                NSDictionary *info = gPending[k];
                [out appendFormat:@"\n  #%@ 起始 +%.1fs 已等 %.1fs  %@",
                 k, [info[@"t"] doubleValue],
                 CFAbsoluteTimeGetCurrent() - gStart - [info[@"t"] doubleValue], info[@"d"]];
            }
        }
    }
    return out;
}

static void PPReport(void) {
    PPLog(@"=== REPORT ===");
    PPLog(@"flags: didFinishLaunching=%d didBecomeActive=%d window=%d flutterVCLoaded=%d flutterVCAppeared=%d",
          gSawFinish, gSawActive, gSawWindow, gSawFlutterLoad, gSawFlutterAppear);
    PPLog(@"engine: runs=%d destroyed=%d ; impeller mode=%d appReadIt=%d",
          gEngineRuns, gEngineDestroyed, gImpellerMode, gImpellerRead);
    PPLog(@"ui thread: everSeen=%d lastSeen=+%.2fs presentNow=%d", gSeenUI, gLastUISeen, gSawUIThread);
    PPLogImages("final images");
    PPLogForeignImages();
    PPLog(@"messages: %@", PPChanSummary());
    PPThreadsFiltered("report", NO);

    void (^ui)(void) = ^{
        NSString *frame = @"未知";
        UIViewController *host = PPKeyWindow().rootViewController;
        @try {
            if ([host respondsToSelector:NSSelectorFromString(@"isDisplayingFlutterUI")]) {
                id v = [host valueForKey:@"displayingFlutterUI"];
                if (v) frame = [v boolValue] ? @"是" : @"否";
            }
        } @catch (NSException *e) {
            frame = @"读取失败";
        }
        PPLog(@"first frame rendered: %@ | hostVC=%@", frame, NSStringFromClass(host.class));
        PPLog(@"--- view tree ---");
        PPLogViewTree(PPKeyWindow(), 1);
        [UIPasteboard generalPasteboard].string = PPFullLog();

        UIViewController *top = PPTopVC();
        if (!top) { PPLog(@"alert skipped: no view controller"); return; }
        NSString *msg = [NSString stringWithFormat:
            @"完整日志已复制到剪贴板，贴给我就行。\n\n"
            @"第一帧已画出：%@\n"
            @"Dart 线程(ui)：%@（最后见到 +%.2fs）\n"
            @"引擎启动次数：%d，被拆次数：%d\n"
            @"注册通道数：%lu\n"
            @"Impeller 干预：%@\n\n%@",
            frame,
            gSawUIThread ? @"还在" : @"已消失",
            gLastUISeen,
            gEngineRuns, gEngineDestroyed,
            (unsigned long)gRegistered.count,
            gImpellerMode == 0 ? @"未干预（App 原设置）" : (gImpellerMode < 0 ? @"强制关闭" : @"强制开启"),
            PPChanSummary()];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"PiliProbe 0.5"
                                                                  message:msg
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [top presentViewController:a animated:YES completion:nil];
    };
    dispatch_async(dispatch_get_main_queue(), ui);
}

// ---------------------------------------------------------------- 启动

__attribute__((constructor)) static void PPInit(void) {
    @autoreleasepool {
        NSBundle *b = NSBundle.mainBundle;
        NSString *bid = b.bundleIdentifier ?: @"";
        NSString *exe = [b objectForInfoDictionaryKey:@"CFBundleExecutable"] ?: @"";
        NSString *name = [b objectForInfoDictionaryKey:@"CFBundleName"] ?: @"";
        NSString *disp = [b objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"";
        NSString *all = [[NSString stringWithFormat:@"%@ %@ %@ %@", bid, exe, name, disp] lowercaseString];
        if ([all rangeOfString:@"pili"].location == NSNotFound) return;  // 只碰 PiliPlus

        gStart = CFAbsoluteTimeGetCurrent();
        gLock = [NSObject new];
        gPending = [NSMutableDictionary dictionary];
        gChanStat = [NSMutableDictionary dictionary];
        gRegistered = [NSMutableArray array];
        gProbeQ = dispatch_queue_create("piliprobe.probe", DISPATCH_QUEUE_SERIAL);

        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
                       ?: NSTemporaryDirectory();
        gLogPath = [docs stringByAppendingPathComponent:@"piliprobe.log"];
        gLogFD = open(gLogPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0644);

        struct utsname u;
        uname(&u);
        PPLog(@"PiliProbe 0.5.0 started. device=%s iOS=%@ bundle=%@ version=%@(%@) exe=%@",
              u.machine, UIDevice.currentDevice.systemVersion, bid,
              [b objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
              [b objectForInfoDictionaryKey:@"CFBundleVersion"], exe);
        PPLog(@"log file: %@", gLogPath);

        if (gLogFD >= 0) {
            dup2(gLogFD, STDOUT_FILENO);
            dup2(gLogFD, STDERR_FILENO);
            PPLog(@"stdout/stderr redirected into this log");
        }

        NSString *offMark = [docs stringByAppendingPathComponent:@"piliprobe_impeller_off"];
        NSString *onMark = [docs stringByAppendingPathComponent:@"piliprobe_impeller_on"];
        if ([fm fileExistsAtPath:offMark]) gImpellerMode = -1;
        else if ([fm fileExistsAtPath:onMark]) gImpellerMode = 1;
        else gImpellerMode = 0;
        id origImpeller = b.infoDictionary[@"FLTEnableImpeller"];
        PPLog(@"Info.plist FLTEnableImpeller = %@ ; override mode = %d (%@)",
              origImpeller ?: @"未设置", gImpellerMode,
              gImpellerMode == 0
                ? @"不干预；想测关 Impeller 就在 Documents 建空文件 piliprobe_impeller_off 后重开"
                : (gImpellerMode < 0 ? @"强制关闭" : @"强制开启"));

        NSString *fw = b.privateFrameworksPath;
        NSArray *items = [fm contentsOfDirectoryAtPath:fw error:nil];
        PPLog(@"Frameworks (%lu): %@", (unsigned long)items.count, [items componentsJoinedByString:@", "]);
        PPLog(@"debug-build marker (kernel_blob.bin) exists: %d",
              [fm fileExistsAtPath:[fw stringByAppendingPathComponent:@"App.framework/flutter_assets/kernel_blob.bin"]]);

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
                    extra = [NSString stringWithFormat:@" window=%@ rootVC=%@",
                             NSStringFromClass(w.class), NSStringFromClass(w.rootViewController.class)];
                    gSawWindow = YES;
                }
                if ([label hasPrefix:@"UIApplicationDidFinish"]) { gSawFinish = YES; PPInstallHooks(); }
                if ([label hasPrefix:@"UIApplicationDidBecomeActive"]) gSawActive = YES;
                PPLog(@"%@%@", label, extra);
            }];
        }

        PPHookBundle();
        PPInstallHooks();

        // 20ms 监听命名线程集合变化（前 3 秒），之后 250ms。
        gWatchTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gProbeQ);
        dispatch_source_set_timer(gWatchTimer, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC),
                                  20 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(gWatchTimer, ^{
            double now = CFAbsoluteTimeGetCurrent() - gStart;
            if (now > 3.0) {
                dispatch_source_set_timer(gWatchTimer, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                                          250 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
            }
            PPWatch();
        });
        dispatch_resume(gWatchTimer);

        // 50ms 一次 PC 采样（前 3 秒），之后 1 秒。
        gSampleTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gProbeQ);
        dispatch_source_set_timer(gSampleTimer, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                                  50 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(gSampleTimer, ^{
            double now = CFAbsoluteTimeGetCurrent() - gStart;
            if (!gPhase && now > 3.0) {
                gPhase = 1;
                dispatch_source_set_timer(gSampleTimer, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                                          1 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
            }
            PPSample();
        });
        dispatch_resume(gSampleTimer);

        gTickTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gProbeQ);
        dispatch_source_set_timer(gTickTimer, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                                  1 * NSEC_PER_SEC, 0);
        dispatch_source_set_event_handler(gTickTimer, ^{ PPTick(); });
        dispatch_resume(gTickTimer);

        // 关键时刻的重点线程全栈（0.15 秒起，之前没有采样点）
        double marks[14] = {0.15, 0.22, 0.30, 0.38, 0.46, 0.55, 0.65,
                            0.78, 0.92, 1.10, 1.40, 2.00, 3.00, 6.00};
        for (int i = 0; i < 14; i++) {
            char lbl[32];
            snprintf(lbl, sizeof lbl, "at %.2fs", marks[i]);
            char *tag = strdup(lbl);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(marks[i] * NSEC_PER_SEC)), gProbeQ, ^{
                PPThreadsFiltered(tag, YES);
                free(tag);
            });
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), gProbeQ, ^{
            PPMetalCheck();
        });

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.5 * NSEC_PER_SEC)), gProbeQ, ^{
            PPReport();
        });
    }
}
