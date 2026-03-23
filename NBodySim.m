#import <MetalKit/MetalKit.h>
#import <simd/simd.h>
#import "Structs.m"
#import "MatrixUtils.m"
#include <iostream>
#define PI 3.1415927

@interface NBodySim : NSObject <MTKViewDelegate>
{
@public
    // Sim parameters
    bool doSimStep;
    NSUInteger threadgroupSize;
    int numParticles;
    double Z_init, deltaTime, radius, softening;
    double G, H0, Omega_m, Omega_lambda;
    double m_0, t_0, r_0;
    double sim_m, sim_r, sim_dt, sim_ep2, sim_a, sim_H;
    ComputeParams params;

    // Compute variables
    id<MTLDevice> device;
    id<MTLCommandQueue> commandQueue;
    id<MTLComputePipelineState> computePipelineState;
    id<MTLRenderPipelineState> renderPipelineState;
    id<MTLBuffer> particleBuffer;
    id<MTLBuffer> particleBufferNext;
    id<MTLBuffer> uniformBuffer;

    // Camera state
    float displaySize;
    float camYaw, camPitch, camDist;
    simd_float3 eye;
    simd_float4x4 viewMatrix;
    simd_float4x4 projectionMatrix;
    simd_float4x4 mvp;
}

- (instancetype)initWithView:(MTKView*)view;
- (void)initParticles;
- (void)updateEye;
- (void)toggleSim;
- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size;
- (void)drawInMTKView:(MTKView*)view;

@end

@implementation NBodySim

- (instancetype)initWithView:(MTKView*)view {
    self = [super init];
    if (!self) return nil;

    // Sim parameters
    threadgroupSize = 250;
    numParticles = 20000;
    Z_init = 30.0;
    deltaTime = 3.154e14;  // s (=10 My)
    radius = 3.086e24;     // cm (=1 Mpc)
    softening = 0.4;

    // Constants
    G = 6.674e-8;    // dyne cm^2 / g^2
    H0 = 2.268e-18;  // s^-1
    Omega_m = 0.3;
    Omega_lambda = 1.0 - Omega_m;  // flat universe

    // Code units
    m_0 = 1.989e40;  // g (=10^7 SM)
    r_0 = 3.086e24;  // cm (=1 Mpc)
    t_0 = r_0 * sqrt(r_0 / (G * m_0));  // s

    // Particle display size
    displaySize = 35.0f;

    if (![self initBuffers: view]) return nil;
    [self initSimState];
    [self initParticles];
    [self initCamera];

    doSimStep = true;

    return self;
}

// Initialize buffers
- (bool)initBuffers:(MTKView *)view {
    device = view.device;
    commandQueue = [device newCommandQueue];
    NSError *err = nil;
    
    // Load metal shader library from disk
    NSURL *libURL = [NSURL fileURLWithPath:@"Shaders.metallib"];

    id<MTLLibrary> lib = [device newLibraryWithURL:libURL error:&err];
    if (!lib) {
        NSLog(@"Failed to load metallib: %@", err);
        return false;
    }

    // Create compute pipeline state
    id<MTLFunction> cfn = [lib newFunctionWithName:@"nbody_kernel"];

    computePipelineState = [device newComputePipelineStateWithFunction:cfn error:&err];
    if (!computePipelineState) {
        NSLog(@"Failed to create compute pipeline state: %@", err);
        return false;
    }

    // Create render pipeline state
    id<MTLFunction> vfn = [lib newFunctionWithName:@"particle_vertex"];
    id<MTLFunction> ffn = [lib newFunctionWithName:@"particle_fragment"];

    MTLRenderPipelineDescriptor *pdesc = [[MTLRenderPipelineDescriptor alloc] init];
    pdesc.vertexFunction = vfn;
    pdesc.fragmentFunction = ffn;
    pdesc.colorAttachments[0].pixelFormat = view.colorPixelFormat;

    // Enable alpha blending
    MTLRenderPipelineColorAttachmentDescriptor *colorAttachment = pdesc.colorAttachments[0];
    colorAttachment.blendingEnabled = YES;
    colorAttachment.rgbBlendOperation = MTLBlendOperationAdd;
    // colorAttachment.alphaBlendOperation = MTLBlendOperationAdd;
    colorAttachment.sourceRGBBlendFactor = MTLBlendFactorOne;
    colorAttachment.destinationRGBBlendFactor = MTLBlendFactorOne;

    renderPipelineState = [device newRenderPipelineStateWithDescriptor:pdesc error:&err];
    if (!renderPipelineState) {
        NSLog(@"Failed to create render pipeline state: %@", err);
        return false;
    }

    // Create buffers
    particleBuffer = [device newBufferWithLength:sizeof(Particle) * numParticles
                                         options:MTLResourceStorageModeShared];
    particleBufferNext = [device newBufferWithLength:sizeof(Particle) * numParticles
                                             options:MTLResourceStorageModeShared];
    uniformBuffer = [device newBufferWithLength:sizeof(Uniforms)
                                        options:MTLResourceStorageModeShared];
    return true;
}

// Initialize simulation state
- (void)initSimState {
    double rho_crit = 3 * H0 * H0 / (8 * PI * G);
    double volume = 4/3.0 * PI * radius * radius * radius;
    double volumePerParticle = volume / numParticles;
    double massPerParticle = rho_crit * volumePerParticle;
    double epsilon2 = cbrt(volumePerParticle) * softening;
    
    // Code variables
    sim_m = massPerParticle / m_0;
    sim_r = radius / r_0;
    sim_dt = deltaTime / t_0;
    sim_ep2 = epsilon2 / r_0;

    // Cosmology variables
    sim_a = 1.0 / (1 + Z_init);
    
    double inv3 = 1.0 / (sim_a * sim_a * sim_a);
    sim_H = H0 * sqrt(Omega_m * inv3 + Omega_lambda) * t_0;

    params.N = numParticles;
    params.dt = sim_dt;
    params.ep2 = sim_ep2;
    params.H = sim_H;
    params.a_inv3 = inv3;

    // std::cout << "r:" << sim_r << " dt:" << sim_dt <<
    //              " m:" << sim_m << " ep2:" << sim_ep2 << "\n";
}

// Initialize particles
- (void)initParticles {
    Particle *particles = (Particle *)particleBuffer.contents;
    Particle *particlesNext = (Particle *)particleBufferNext.contents;

    for (int i=0;i<numParticles;++i) {
        // Uniform sphere
        float r = cbrtf((float)rand() / RAND_MAX) * sim_r;
        float theta = ((float)rand() / RAND_MAX) * 2.0f * M_PI;
        float phi = acosf(2.0f * ((float)rand() / RAND_MAX) - 1.0f);
        float x = r * sinf(phi) * cosf(theta);
        float y = r * sinf(phi) * sinf(theta);
        float z = r * cosf(phi);

        particles[i].pos = (simd_float3){x,y,z};
        particles[i].vel = (simd_float3){0,0,0};
        particles[i].mass = sim_m;
        particles[i].color = (simd_float3) { 1.0, 1.0, 1.0 };
        particlesNext[i] = particles[i];
    }
}

// Initialize camera state
- (void)initCamera {
    camYaw = 0.0f;
    camPitch = 0.3f;
    camDist = 4.0f;
    [self updateEye];
}

// Update eye vector and rebuild view matrix
- (void)updateEye {
    float cx = camDist * cosf(camPitch) * sinf(camYaw);
    float cy = camDist * sinf(camPitch);
    float cz = camDist * cosf(camPitch) * cosf(camYaw);

    eye = { cx, cy, cz };
    simd_float3 center = { 0, 0, 0 };
    simd_float3 up = { 0, 1, 0 };
    viewMatrix = getViewMatrix(eye, center, up);
}

// Toggle simulation
- (void)toggleSim {
    doSimStep = !doSimStep;
}

// MTKViewDelegate method - called when drawable size changes
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

// MTKViewDelegate method - draw
- (void)drawInMTKView:(MTKView *)view {
    // Build matrices
    projectionMatrix = getProjectionMatrix(60.0f * (M_PI/180.0f),
                                           view.drawableSize.width/view.drawableSize.height,
                                           0.01f, 100.0f);
    mvp = simd_mul(projectionMatrix, viewMatrix);

    // Copy to buffer
    Uniforms u;
    u.mvp = mvp;
    u.eye = eye;
    u.vertSize = displaySize;
    memcpy(uniformBuffer.contents, &u, sizeof(Uniforms));

    id<MTLCommandBuffer> cmd = [commandQueue commandBuffer];

    if (doSimStep) {
        // Update cosmology variables
        sim_a += sim_H * sim_a * sim_dt;

        double inv3 = 1.0 / (sim_a * sim_a * sim_a);
        sim_H = H0 * sqrt(Omega_m * inv3 + Omega_lambda) * t_0;

        params.H = sim_H;
        params.a_inv3 = inv3;
        
        // --- Compute pass ---
        
        // Swap buffers
        id<MTLBuffer> tmp = particleBuffer;
        particleBuffer = particleBufferNext;
        particleBufferNext = tmp;
        
        NSUInteger numThreadgroups = numParticles / threadgroupSize;

        MTLSize groupSize = MTLSizeMake(threadgroupSize, 1, 1);
        MTLSize numGroups = MTLSizeMake(numThreadgroups, 1, 1);

        id<MTLComputeCommandEncoder> cenc = [cmd computeCommandEncoder];

        [cenc setComputePipelineState:computePipelineState];
        [cenc setBuffer:particleBuffer offset:0 atIndex:0];
        [cenc setBuffer:particleBufferNext offset:0 atIndex:1];
        [cenc setBytes:&params length:sizeof(ComputeParams) atIndex:2];

        [cenc dispatchThreadgroups:numGroups threadsPerThreadgroup:groupSize];
        [cenc endEncoding];

        // Particle *particles = (Particle *)particleBuffer.contents;
        // simd_float3 momentum = (simd_float3){0,0,0};

        // for (int i=0;i<numParticles;++i) {
        //     momentum += particles[i].vel * particles[i].mass;
        // }
        // std::cout << "P: " << momentum[0] << "\n";
    }

    // --- Render pass ---

    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    if (!rpd) return; // no drawable available

    id<MTLRenderCommandEncoder> renc = [cmd renderCommandEncoderWithDescriptor:rpd];
    [renc setRenderPipelineState:renderPipelineState];
    [renc setVertexBuffer:particleBuffer offset:0 atIndex:0];
    [renc setVertexBuffer:uniformBuffer offset:0 atIndex:1];
    [renc drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:numParticles];
    [renc endEncoding];

    [cmd presentDrawable:view.currentDrawable];
    [cmd commit];
}

@end