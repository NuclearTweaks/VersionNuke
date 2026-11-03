// VersionNuke — AppStore++ style version picker — long-press Get/Update in the App Store to choose which version to install. Pin an app to a known-good build before an update breaks it.
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>

//%hook SomeClass
//- (void)someMethod {
//    NSLog(@"[VersionNuke] someMethod");
//    %orig;
//}
//%end

%ctor {
    NSLog(@"[VersionNuke] loaded into %@ (pid %d)",
          [NSProcessInfo processInfo].processName,
          [[NSProcessInfo processInfo] processIdentifier]);
}
