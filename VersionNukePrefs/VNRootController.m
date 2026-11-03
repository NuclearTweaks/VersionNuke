// VersionNukePrefs — Settings pane (PreferenceLoader bundle).
// Runtime-resolved private Preferences classes (same proven pattern as
// NotificationNukePrefs). Pin state lands in the tweak's preference domain +
// a Darwin notification; appstored reloads live.

#import <UIKit/UIKit.h>

static NSString *const kDomain  = @"com.nucleartweaks.version-nuke";
static NSString *const kChanged = @"com.nucleartweaks.version-nuke/changed";

@interface PSSpecifier : NSObject
- (NSMutableDictionary *)properties;
- (void)setProperty:(id)prop forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
@end

@interface PSListController : UIViewController
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (NSArray *)specifiers;
- (PSSpecifier *)specifier;
- (void)reloadSpecifiers;
@end

// ─── prefs helpers ──────────────────────────────────────────────────────────

static id VNGet(NSString *key) {
    CFStringRef dom = (__bridge CFStringRef)kDomain;
    CFPreferencesAppSynchronize(dom);
    CFTypeRef v = CFPreferencesCopyValue((__bridge CFStringRef)key, dom,
                        kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    return v ? CFBridgingRelease(v) : nil;
}
static void VNSet(NSString *key, id value) {
    CFStringRef dom = (__bridge CFStringRef)kDomain;
    CFPreferencesSetValue((__bridge CFStringRef)key,
                          value ? (__bridge CFTypeRef)value : NULL,
                          dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesAppSynchronize(dom);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kChanged, NULL, NULL, true);
}

static NSDictionary *VNPins(void) {
    id v = VNGet(@"pins");
    return [v isKindOfClass:NSDictionary.class] ? v : @{};
}
static void VNSetPin(NSString *bid, id dictOrNil) {
    NSMutableDictionary *pins = [VNPins() mutableCopy];
    if (dictOrNil) pins[bid] = dictOrNil; else [pins removeObjectForKey:bid];
    VNSet(@"pins", pins);
}
// daemon's learned ledger (display copy; file inside appstored's container is authoritative)
static NSDictionary *VNLedger(void) {
    id v = VNGet(@"ledgerObserved");
    return [v isKindOfClass:NSDictionary.class] ? v : @{};
}

// current installed version of an LSApplicationProxy (private property, KVC-safe)
static NSString *VNAppVersion(id proxy) {
    NSString *v = nil;
    @try { v = [proxy valueForKey:@"bundleVersion"]; } @catch (id e) {}
    return v.length ? v : @"?";
}
static NSString *VNAppName(id proxy) {
    NSString *n = nil;
    @try { n = [proxy performSelector:@selector(localizedName)]; } @catch (id e) {}
    return n.length ? n : nil;
}

static PSSpecifier *VNSpec(Class cls, NSString *cellClass, NSString *label) {
    PSSpecifier *s = [[cls alloc] init];
    if (cellClass) { [s setProperty:cellClass forKey:@"Cell"]; [s setProperty:cellClass forKey:@"cell"]; }
    if (label)     { [s setProperty:label forKey:@"label"]; [s setProperty:label forKey:@"Title"]; }
    return s;
}
static void VNSpecGetSet(PSSpecifier *s, NSString *get, NSString *set) {
    [s setProperty:get forKey:@"get"]; [s setProperty:get forKey:@"Get"];
    [s setProperty:set forKey:@"set"]; [s setProperty:set forKey:@"Set"];
}

// ─── root ───────────────────────────────────────────────────────────────────

@interface VNRootController : PSListController
@end

@implementation VNRootController

- (NSArray *)specifiers {
    return [self loadSpecifiersFromPlistName:@"Root" target:self];
}
- (id)readEnabled:(id)spec {
    id v = VNGet(@"enabled");
    return (v && [v isKindOfClass:NSNumber.class]) ? v : @YES;
}
- (void)writeEnabled:(id)val forSpecifier:(id)spec {
    VNSet(@"enabled", [val boolValue] ? (id)kCFBooleanTrue : (id)kCFBooleanFalse);
}

@end

// ─── apps list ──────────────────────────────────────────────────────────────

@interface VNAppListController : PSListController
@end

@implementation VNAppListController

- (NSArray *)specifiers {
    NSMutableArray *out = [NSMutableArray array];
    Class WS = NSClassFromString(@"LSApplicationWorkspace");
    id ws = [WS performSelector:@selector(defaultWorkspace)];
    NSArray *apps = [ws performSelector:@selector(deviceApplications)];
    NSDictionary *pins = VNPins();
    NSMutableArray *rows = [NSMutableArray array];
    for (id app in apps) {
        NSString *bid = [app performSelector:@selector(bundleIdentifier)];
        NSString *name = VNAppName(app);
        if (!bid.length || !name.length) continue;      // user apps with real names
        NSString *ver = VNAppVersion(app);
        BOOL pinned = [pins[bid] isKindOfClass:NSDictionary.class];
        [rows addObject:@{ @"bid": bid, @"name": name, @"ver": ver,
                           @"detail": pinned ? [NSString stringWithFormat:@"pinned · v%@", ver]
                                             : [NSString stringWithFormat:@"v%@", ver] }];
    }
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    for (NSDictionary *r in rows) {
        PSSpecifier *s = VNSpec(NSClassFromString(@"PSSpecifier"), @"PSLinkListCell", r[@"name"]);
        [s setProperty:r[@"detail"] forKey:@"detailText"];
        [s setProperty:@"VNAppDetailController" forKey:@"detail"];
        [s setProperty:r[@"bid"] forKey:@"vnBid"];
        [s setProperty:r[@"ver"] forKey:@"vnVer"];
        [out addObject:s];
    }
    return out;
}

@end

// ─── per-app page ───────────────────────────────────────────────────────────

@interface VNAppDetailController : PSListController
@end

@implementation VNAppDetailController

- (NSString *)bid  { return [[self specifier] propertyForKey:@"vnBid"] ?: @""; }
- (NSString *)ver  { return [[self specifier] propertyForKey:@"vnVer"] ?: @"?"; }

- (NSArray *)specifiers {
    NSMutableArray *out = [NSMutableArray array];
    NSString *bid = [self bid];
    NSString *appName = [[self specifier] propertyForKey:@"label"];
    NSDictionary *led = [VNLedger()[bid] isKindOfClass:NSDictionary.class] ? VNLedger()[bid] : nil;
    Class Group = NSClassFromString(@"PSGroupSpecifier");
    Class Spec  = NSClassFromString(@"PSSpecifier");

    PSSpecifier *g1 = VNSpec(Group, nil, nil);
    [g1 setProperty:[NSString stringWithFormat:
        @"Current version: %@%@. Pinning makes the App Store daemon treat THIS build as the store's latest for you: no update offers, auto-update stays put, a manual Update reinstalls the same build.",
        [self ver],
        led[@"versionID"] ? [NSString stringWithFormat:@" (store version id %@)", led[@"versionID"]] : @""]
        forKey:@"footerText"];
    [out addObject:g1];

    PSSpecifier *sw = VNSpec(Spec, @"PSSwitchCell",
        [NSString stringWithFormat:@"Pin %@ to v%@", appName ?: @"app", [self ver]]);
    VNSpecGetSet(sw, @"readPinned:", @"writePinned:forSpecifier:");
    [out addObject:sw];

    PSSpecifier *g2 = VNSpec(Group, nil, nil);
    [g2 setProperty:@"Advanced (optional): override what the pin resolves to. Leave blank to pin the app's current, daemon-observed version. A forced version id is only installable if Apple's CDN still serves that build." forKey:@"footerText"];
    [out addObject:g2];

    PSSpecifier *bv = VNSpec(Spec, @"PSEditTextCell", @"Force version string");
    [bv setProperty:@"e.g. 10.28" forKey:@"placeholder"];
    [bv setProperty:@"bundleVersion" forKey:@"vnKey"];
    VNSpecGetSet(bv, @"readAdv:", @"writeAdv:forSpecifier:");
    [out addObject:bv];

    PSSpecifier *vid = VNSpec(Spec, @"PSEditTextCell", @"Force version id");
    [vid setProperty:@"e.g. 6449932912" forKey:@"placeholder"];
    [vid setProperty:@"versionID" forKey:@"vnKey"];
    VNSpecGetSet(vid, @"readAdv:", @"writeAdv:forSpecifier:");
    [out addObject:vid];

    return out;
}

- (id)readPinned:(id)spec {
    return [VNPins()[[self bid]] isKindOfClass:NSDictionary.class] ? @YES : @NO;
}
- (void)writePinned:(id)val forSpecifier:(id)spec {
    if ([val boolValue]) {
        // pin to the daemon-observed current version (empty dict = learned),
        // but snapshot the LS version string so the pin survives even before
        // the daemon first records it.
        VNSetPin([self bid], @{ @"bundleVersion": [self ver] });
    } else {
        VNSetPin([self bid], nil);
    }
    [self reloadSpecifiers];
}

- (id)readAdv:(id)spec {
    NSString *key = [(PSSpecifier *)spec propertyForKey:@"vnKey"];
    id pin = VNPins()[[self bid]];
    if (![pin isKindOfClass:NSDictionary.class]) return @"";
    return pin[key] ?: @"";
}
- (void)writeAdv:(id)val forSpecifier:(id)spec {
    NSString *key = [(PSSpecifier *)spec propertyForKey:@"vnKey"];
    NSString *s = [val isKindOfClass:NSString.class]
                ? [val stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] : @"";
    NSString *bid = [self bid];
    NSMutableDictionary *pin = [VNPins()[bid] isKindOfClass:NSDictionary.class]
                             ? [VNPins()[bid] mutableCopy]
                             : [@{ @"bundleVersion": [self ver] } mutableCopy];
    if (s.length) pin[key] = s; else [pin removeObjectForKey:key];
    VNSetPin(bid, pin);   // editing implies pinned
}

@end
