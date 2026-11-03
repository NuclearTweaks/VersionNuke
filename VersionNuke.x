// VersionNuke — pin App Store apps to a chosen version so updates never move
// them off a known-good build.
//
// iOS 27's App Store pipeline (AppStoreDaemon, process `appstored`) decides
// WHICH build to download from version identifiers that flow through a small
// set of objects (class/method list verified against the live iOS 27
// AppStoreDaemon via a runtime probe):
//
//   ASDAppLedgerItem        initWithBundleID:bundleVersion:itemID:versionID:…
//                           ← the daemon's record of what is INSTALLED. We
//                             observe every ledger read/write into our own
//                             learned ledger {bundleID → {bundleVersion,
//                             itemID, versionID}} so we always know each app's
//                             current version AND its external version id.
//   ASDApplicationMetadata  -bundleVersion / -shortVersion /
//                           -externalVersionIdentifier
//                           ← what the store says to install. If an app is
//                             pinned, we answer with the pinned build instead.
//   ASDManagedApplicationRequestOptions / ASDSoftwareUpdate -externalVersionIdentifier
//                           ← repair & update paths get the same lie.
//
// Net effect for a pinned app: the daemon believes the store's "latest" IS the
// pinned build — the app stops offering updates, auto-update resolves to the
// pinned version id, and a manual update reinstalls the pinned build rather
// than the new one. Unpin → immediate return to normal behavior.
//
// The pin target defaults to the version observed at pin time (captured from
// the ledger; the Settings pane shows it); power users can enter an explicit
// bundleVersion / version id from Settings.
//
// Config (domain com.nucleartweaks.version-nuke, live-reloaded via Darwin
// notification):
//   enabled  BOOL (default YES)
//   pins     dict bundleID → { bundleVersion: str?, shortVersion: str?,
//                              versionID: str/num? }   empty dict = pin to the
//   learned version for that app.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#import <dlfcn.h>

typedef void (*VN_MSHook)(Class, SEL, IMP, IMP *);

static NSString *const kDomain  = @"com.nucleartweaks.version-nuke";
static NSString *const kChanged = @"com.nucleartweaks.version-nuke/changed";

static os_log_t gLog;
static int gBudget = 40;
static BOOL gEnabled = YES;
static NSDictionary *gPins;                       // bundleID -> dict
static NSMutableDictionary *gLedger;              // bundleID -> {bundleVersion,itemID,versionID}
static NSString *gLedgerPath;
static NSTimeInterval gLastSave;

// ─── logging ────────────────────────────────────────────────────────────────

static void VNLog(NSString *fmt, ...) {
    if (gBudget <= 0) return;
    gBudget--;
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    os_log(gLog, "%{public}@", s);
    NSLog(@"[VersionNuke] %@", s);
    FILE *pf = fopen("/Users/spencer/versionnuke-proof.txt", "a");   // JB sim host FS; absent on device
    if (pf) { fprintf(pf, "%s\n", s.UTF8String); fclose(pf); }
}

// ─── config + learned ledger ───────────────────────────────────────────────

static void VNReload(void) {
    CFStringRef dom = (__bridge CFStringRef)kDomain;
    CFPreferencesAppSynchronize(dom);
    CFTypeRef v;
    BOOL enabled = YES;
    v = CFPreferencesCopyValue(CFSTR("enabled"), dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (v) { if (CFGetTypeID(v) == CFBooleanGetTypeID()) enabled = CFBooleanGetValue((CFBooleanRef)v); CFRelease(v); }
    NSDictionary *pins = nil;
    v = CFPreferencesCopyValue(CFSTR("pins"), dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (v) { if (CFGetTypeID(v) == CFDictionaryGetTypeID()) pins = CFBridgingRelease(v); else CFRelease(v); }
    @synchronized (gLedger) {
        gEnabled = enabled;
        gPins = pins ?: @{};
    }
}

static void VNChanged(CFNotificationCenterRef c, void *obs, CFNotificationName n, const void *p, CFDictionaryRef u) {
    VNReload();
}

static void VNLedgerLoad(void) {
    gLedgerPath = [NSHomeDirectory() stringByAppendingPathComponent:
                   @"Library/Caches/com.nucleartweaks.version-nuke.ledger.plist"];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:gLedgerPath];
    gLedger = d ? [d mutableCopy] : [NSMutableDictionary dictionary];
}
static void VNLedgerSave(void) {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - gLastSave < 5.0) return;              // debounce: ledger replays are bursty
    gLastSave = now;
    @try { [gLedger writeToFile:gLedgerPath atomically:YES]; } @catch (id e) {}
    @try {                                            // display copy for the Settings pane
        NSDictionary *copy = [gLedger copy];
        CFStringRef dom = (__bridge CFStringRef)kDomain;
        CFPreferencesSetValue(CFSTR("ledgerObserved"), (__bridge CFTypeRef)copy, dom,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFPreferencesAppSynchronize(dom);
    } @catch (id e) {}
}

// ─── the version lie ────────────────────────────────────────────────────────
// Returns the pinned replacement for bundleID, or nil = tell the truth.
// key: @"versionID" → NSNumber/NSString id, @"bundleVersion"/@"shortVersion" → str.

static id VNPinned(NSString *bundleID, NSString *key) {
    if (!gEnabled || bundleID.length == 0) return nil;
    NSDictionary *pin = gPins[bundleID];
    if (![pin isKindOfClass:NSDictionary.class]) return nil;      // not pinned
    id explicitVal = pin[key];
    if ([explicitVal isKindOfClass:NSString.class] && [explicitVal length] == 0) explicitVal = nil;
    if (explicitVal) return explicitVal;
    NSDictionary *seen = gLedger[bundleID];                       // learned value
    if (![seen isKindOfClass:NSDictionary.class]) return nil;     // pin armed but never observed → truth
    return seen[key];
}

// versionID lives in the ledger under "versionID" but metadata/updates call it
// externalVersionIdentifier; normalize both spellings.
static id VNPinnedVersionID(NSString *bundleID) {
    id v = VNPinned(bundleID, @"versionID");
    if (!v) v = VNPinned(bundleID, @"externalVersionIdentifier");
    if ([v isKindOfClass:NSString.class]) v = @([v longLongValue]);   // prefs may store as string
    return v;
}

// ─── substrate resolution (same pattern as NotificationNuke) ───────────────

static VN_MSHook VNFindSubstrate(void) {
    VN_MSHook h = (VN_MSHook)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (h) return h;
    static const char *homes[] = {
        "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",        // rootful (JB sim)
        "/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
        "/var/jb/usr/lib/libellekit.dylib",
        "/var/jb/usr/lib/libsubstitute.dylib",
        "/var/jb/usr/lib/TweakLoader.dylib",
        "/usr/lib/libsubstitute.dylib",
    };
    for (size_t i = 0; i < sizeof(homes)/sizeof(homes[0]) && !h; i++) {
        void *img = dlopen(homes[i], RTLD_LAZY);
        if (img) h = (VN_MSHook)dlsym(img, "MSHookMessageEx");
    }
    return h;
}

// ─── hooks ──────────────────────────────────────────────────────────────────

static VN_MSHook gHook;
static void VNHook(Class c, SEL sel, IMP rep, IMP *orig) {
    if (gHook && c && class_getInstanceMethod(c, sel)) gHook(c, sel, rep, orig);
}

// plain message send: the bundleID/bundleIdentifier getters are NOT hooked,
// so normal dispatch cannot recurse into our replacements.
static NSString *VNBid(id self, SEL idSel) {
    @try { return ((id (*)(id, SEL))objc_msgSend)(self, idSel); } @catch (id e) { return nil; }
}

// 1) learn: the daemon's ledger tells us what is installed, with version ids.
typedef id (*VN_LedgerInit)(id, SEL, id, id, id, id, id, id);
static VN_LedgerInit orig_ledgerInit;
static id rep_ledgerInit(id self, SEL s, id bundleID, id bundleVersion, id itemID,
                         id versionID, id installDate, id lastLaunch) {
    id r = orig_ledgerInit(self, s, bundleID, bundleVersion, itemID, versionID, installDate, lastLaunch);
    @try {
        if ([bundleID isKindOfClass:NSString.class] && [(NSString *)bundleID length] && versionID) {
            @synchronized (gLedger) {
                id oldKey = gLedger[bundleID][@"versionID"];
                BOOL changed = ![[oldKey description] isEqualToString:[versionID description]];
                gLedger[bundleID] = @{ @"bundleVersion": bundleVersion ?: @"",
                                       @"itemID": itemID ?: @"",
                                       @"versionID": versionID };
                if (changed) {
                    VNLedgerSave();
                    VNLog(@"ledger %@ -> %@ (%@)", bundleID, versionID, bundleVersion);
                }
            }
        }
    } @catch (id e) {}
    return r;
}

// 2) lie: ASDApplicationMetadata version triple.
static IMP orig_metaEVI, orig_metaBV, orig_metaSV;
static id rep_metaEVI(id self, SEL s) {
    id real = ((id (*)(id, SEL))orig_metaEVI)(self, s);
    id pin = VNPinnedVersionID(VNBid(self, @selector(bundleID)));
    return pin ?: real;
}
static id rep_metaStr(IMP orig, SEL selfSel, NSString *key, id self, SEL s) {
    id real = ((id (*)(id, SEL))orig)(self, s);
    id pin = VNPinned(VNBid(self, selfSel), key);
    return pin ?: real;
}
static id rep_metaBV(id self, SEL s) { return rep_metaStr(orig_metaBV, @selector(bundleID), @"bundleVersion", self, s); }
static id rep_metaSV(id self, SEL s) { return rep_metaStr(orig_metaSV, @selector(bundleID), @"shortVersion", self, s); }

// 3) lie: repair / managed-request path.
static IMP orig_optEVI;
static id rep_optEVI(id self, SEL s) {
    id real = ((id (*)(id, SEL))orig_optEVI)(self, s);
    id pin = VNPinnedVersionID(VNBid(self, @selector(bundleIdentifier)));
    return pin ?: real;
}

// 4) lie: the update list entries for pinned apps resolve to the pinned build.
static IMP orig_updEVI;
static id rep_updEVI(id self, SEL s) {
    id real = ((id (*)(id, SEL))orig_updEVI)(self, s);
    id pin = VNPinnedVersionID(VNBid(self, @selector(bundleIdentifier)));
    return pin ?: real;
}

%ctor {
    @autoreleasepool {
        Class meta = NSClassFromString(@"ASDApplicationMetadata");
        Class ledger = NSClassFromString(@"ASDAppLedgerItem");
        if (!meta && !ledger) return;                    // not appstored
        gLog = os_log_create("com.nucleartweaks", "VersionNuke");
        VNLedgerLoad();
        VNReload();
        gHook = VNFindSubstrate();
        if (!gHook) { NSLog(@"[VersionNuke] no substrate symbol — idle"); return; }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, VNChanged, (__bridge CFStringRef)kChanged, NULL,
                                        CFNotificationSuspensionBehaviorCoalesce);

        VNHook(ledger, NSSelectorFromString(@"initWithBundleID:bundleVersion:itemID:versionID:installDate:lastLaunchDate:"),
               (IMP)rep_ledgerInit, (IMP *)&orig_ledgerInit);
        VNHook(meta, NSSelectorFromString(@"externalVersionIdentifier"), (IMP)rep_metaEVI, (IMP *)&orig_metaEVI);
        VNHook(meta, NSSelectorFromString(@"bundleVersion"),             (IMP)rep_metaBV,  (IMP *)&orig_metaBV);
        VNHook(meta, NSSelectorFromString(@"shortVersion"),              (IMP)rep_metaSV,  (IMP *)&orig_metaSV);
        VNHook(NSClassFromString(@"ASDManagedApplicationRequestOptions"),
               NSSelectorFromString(@"externalVersionIdentifier"), (IMP)rep_optEVI, (IMP *)&orig_optEVI);
        VNHook(NSClassFromString(@"ASDSoftwareUpdate"),
               NSSelectorFromString(@"externalVersionIdentifier"), (IMP)rep_updEVI, (IMP *)&orig_updEVI);

        VNLog(@"installed (enabled=%d pins=%lu ledger=%lu)",
              gEnabled, (unsigned long)gPins.count, (unsigned long)gLedger.count);
    }
}
