// PiliFix — makes PiliPlus start on iOS 17.
//
// The app's Dart native-assets manifest names its FFI libraries by relative
// paths ("objective_c.framework/objective_c"). An iOS app runs with cwd "/",
// so dyld cannot find them, the FFI bindings never load, and main() stalls
// before the first frame. Hook dlopen and look a relative path up inside the
// app bundle instead. Nothing in the app is modified.
#import <Foundation/Foundation.h>
#import <os/log.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <unistd.h>
#import <stdio.h>
#import <string.h>

#ifndef APELIN_BUILD_ID
#define APELIN_BUILD_ID "dev"
#endif

typedef void (*mshook_fn_t)(void *symbol, void *replace, void **result);

static void *(*orig_dlopen)(const char *, int);

// <bundle>/<path> or <bundle>/Frameworks/<path>, whichever exists.
static const char *pifix_locate(const char *path, char *buf, size_t size) {
    if (!path || path[0] == '/' || !strchr(path, '/')) return NULL;
    if (access(path, F_OK) == 0) return NULL; // dyld can already find it
    NSString *rel = [NSString stringWithUTF8String:path];
    NSString *bundle = NSBundle.mainBundle.bundlePath;
    if (!rel || bundle.length == 0) return NULL;
    NSString *cands[2] = {
        [bundle stringByAppendingPathComponent:rel],
        [bundle stringByAppendingPathComponent:[@"Frameworks" stringByAppendingPathComponent:rel]],
    };
    for (int i = 0; i < 2; i++) {
        const char *p = cands[i].fileSystemRepresentation;
        if (p && access(p, F_OK) == 0) {
            snprintf(buf, size, "%s", p);
            return buf;
        }
    }
    return NULL;
}

static void *pifix_dlopen(const char *path, int mode) {
    char fixed[1200];
    const char *use = path;
    if (path) {
        const char *found = pifix_locate(path, fixed, sizeof fixed);
        if (found) use = found;
    }
    return orig_dlopen(use, mode);
}

// ElleKit exports MSHookFunction; it sits in the roothide jbroot, which is
// worked out from an image already loaded (never hard-coded: it changes).
static void *pifix_find_hook(void) {
    void *sym = dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (sym) return sym;

    char jbroot[1024] = "";
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        const char *lib = strstr(name, "/usr/lib/");
        const char *jbr = strstr(name, ".jbroot-");
        if (lib && jbr && jbr < lib) {
            size_t len = (size_t)(lib - name);
            if (len < sizeof jbroot) {
                memcpy(jbroot, name, len);
                jbroot[len] = 0;
            }
            break;
        }
    }

    const char *cands[3] = {NULL, NULL, NULL};
    char a[1100], b[1100];
    if (jbroot[0]) {
        snprintf(a, sizeof a, "%s/usr/lib/libellekit.dylib", jbroot);
        snprintf(b, sizeof b, "%s/usr/lib/libsubstrate.dylib", jbroot);
        cands[0] = a;
        cands[1] = b;
    }
    cands[2] = "/usr/lib/libellekit.dylib";
    for (int i = 0; i < 3; i++) {
        if (!cands[i]) continue;
        void *h = dlopen(cands[i], RTLD_NOW | RTLD_GLOBAL);
        if (!h) continue;
        void *q = dlsym(h, "MSHookFunction");
        if (q) return q;
    }
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        if (!strstr(name, "ellekit") && !strstr(name, "substrate")) continue;
        void *h = dlopen(name, RTLD_NOW | RTLD_GLOBAL);
        if (!h) continue;
        void *q = dlsym(h, "MSHookFunction");
        if (q) return q;
    }
    return NULL;
}

__attribute__((constructor)) static void pifix_init(void) {
    os_log_t log = os_log_create("local.apelin.pilifix", "tweak");
    os_log_with_type(log, OS_LOG_TYPE_DEFAULT, "ApelinLoaded " APELIN_BUILD_ID);

    // A file marker as well: the unified log does not always carry the app's
    // own os_log lines, and this says plainly whether the hook went in.
    NSString *mark = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/.pilifix.status"];
    char stamp[160];
    snprintf(stamp, sizeof stamp, "%s build=%s\n", "PiliFix", APELIN_BUILD_ID);
    [[NSString stringWithUTF8String:stamp] writeToFile:mark atomically:YES
                                              encoding:NSUTF8StringEncoding error:NULL];

    mshook_fn_t hook = (mshook_fn_t)pifix_find_hook();
    if (!hook) {
        os_log_with_type(log, OS_LOG_TYPE_ERROR, "PiliFix: ElleKit not reachable, no fix applied");
        return;
    }
    hook((void *)dlopen, (void *)pifix_dlopen, (void **)&orig_dlopen);
    if (!orig_dlopen) {
        orig_dlopen = (void *(*)(const char *, int))dlsym(RTLD_DEFAULT, "dlopen");
    }
    os_log_with_type(log, OS_LOG_TYPE_DEFAULT, "PiliFix: dlopen hooked (%{public}p)", (void *)orig_dlopen);
}
