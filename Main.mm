#import <Metal/Metal.h>
#import "NBodySim.m"
#import "CameraView.m"
#include <iostream>
#include <string>
#include <map>

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AppDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}
@end

int main(int argc, const char* argv[]) {
    std::map<std::string, std::string> argMap;
    for (int i=1; i<argc-1; i+=2)
        argMap[argv[i]] = argv[i+1];

    @autoreleasepool {
        [NSApplication sharedApplication];

        AppDelegate *delegate = [[AppDelegate alloc] init];
        [NSApp setDelegate:delegate];

        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        NSRect frame = NSMakeRect(100, 100, 640, 480);
        NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                       styleMask:(NSWindowStyleMaskTitled |
                                                                  NSWindowStyleMaskClosable |
                                                                  NSWindowStyleMaskResizable)
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        [window setTitle:@"N-Body Gravity Sim"];
        [window makeKeyAndOrderFront:nil];

        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            NSLog(@"Metal is not supported on this system");
            return 1;
        }

        CameraView *cv = [[CameraView alloc] initWithFrame:window.contentView.bounds device:dev];
        cv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [window.contentView addSubview:cv];

        NBodySim *sim = [[NBodySim alloc] initWithView:cv parameters:argMap];
        cv.sim = sim;
        cv.delegate = sim;

        [NSApp activateIgnoringOtherApps:YES];
        [NSApp run];
    }

    return 0;
}