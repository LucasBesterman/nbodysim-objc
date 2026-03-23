#import <MetalKit/MetalKit.h>
#import "NBodySim.m"
#include <iostream>
#include <chrono>
#include <thread>

@class NBodySim;

@interface CameraView : MTKView
@property (nonatomic, assign) NBodySim *sim;
@property (nonatomic) float lastX;
@property (nonatomic) float lastY;
@property (nonatomic) BOOL isDragging;
@end

@implementation CameraView

- (instancetype)initWithFrame:(NSRect)frameRect device:(id<MTLDevice>)device {
    self = [super initWithFrame:frameRect device:device];
    if (self) {
        self.isDragging = NO;
        self.lastX = 0;
        self.lastY = 0;
    }
    return self;
}

- (BOOL)acceptsFirstResponder { return YES; }
- (void)viewDidMoveToWindow { [self.window makeFirstResponder:self]; }

// Mouse pressed: start dragging
- (void)mouseDown:(NSEvent *)event {
    self.isDragging = YES;
    NSPoint loc = [self convertPoint:[event locationInWindow] fromView:nil];
    self.lastX = loc.x;
    self.lastY = loc.y;
}

// Mouse dragged: update yaw/pitch
- (void)mouseDragged:(NSEvent *)event {
    if (!self.isDragging) return;
    NSPoint loc = [self convertPoint:[event locationInWindow] fromView:nil];
    float dx = self.lastX - loc.x;
    float dy = self.lastY - loc.y;

    self.sim->camYaw += dx * 0.01f;
    self.sim->camPitch += dy * 0.01f;

    if (self.sim->camPitch > M_PI_2) self.sim->camPitch = M_PI_2 - 1e-6;
    if (self.sim->camPitch < -M_PI_2) self.sim->camPitch = -M_PI_2 + 1e-6;

    self.lastX = loc.x;
    self.lastY = loc.y;

    [self.sim updateEye];
}

// Mouse released: stop dragging
- (void)mouseUp:(NSEvent *)event {
    self.isDragging = NO;
}

// Scroll wheel: zoom in/out
- (void)scrollWheel:(NSEvent *)event {
    float zoomSpeed = 0.001f;
    self.sim->camDist *= 1 - event.scrollingDeltaY * zoomSpeed;

    if (self.sim->camDist < 0.01f) self.sim->camDist = 0.01f;
    if (self.sim->camDist > 100.0f) self.sim->camDist = 100.0f;

    [self.sim updateEye];
}

// Key pressed: toggle simulation (space) and reset ('r')
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 49) { // space
        [self.sim toggleSim];
    } else if (event.keyCode == 15) { // 'r'
        bool active = self.sim->doSimStep;

        if (active) {
            [self.sim toggleSim];
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
        }

        [self.sim initSimState];
        [self.sim initParticles];
        
        if (active) [self.sim toggleSim];
    }

    [super keyDown:event];
}

@end