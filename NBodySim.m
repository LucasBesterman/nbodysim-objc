#import <MetalKit/MetalKit.h>
#import <simd/simd.h>
#import "Structs.m"
#import "MatrixHelpers.m"

@interface NBodySim : NSObject <MTKViewDelegate>
{
@public
    id<MTLDevice> device;
    id<MTLCommandQueue> commandQueue;
    id<MTLComputePipelineState> computePipelineState;
    id<MTLRenderPipelineState> renderPipelineState;
    id<MTLBuffer> particleBuffer;
    id<MTLBuffer> particleBufferNext;
    id<MTLBuffer> uniformBuffer;

    // Whether to do a simulation step
    BOOL doSimStep;

    // Simulation parameters
    int threadgroup_size;
    float particle_display_size;
    float initial_radius;
    ComputeParams simParams;

    // Camera state variables
    float camYaw;
    float camPitch;
    float camRadius;

    simd_float3 eye;

    // Matrices
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

    // Simulation is active by default
    doSimStep = true;

    // Initialize simulation parameters
    threadgroup_size = 250;
    particle_display_size = 25.0f;
    initial_radius = 1.5f;

    simParams.numParticles = 20000;
    simParams.deltaTime = 0.1f;
    simParams.G = 0.000001f;
    simParams.epsilonSq = 0.005f;
    simParams.expansionFactor = 0.0f;

    // Initialize camera state
    camYaw = 0.0f;
    camPitch = 0.3f;
    camRadius = 4.0f;

    [self updateEye];

    device = view.device;
    commandQueue = [device newCommandQueue];

    NSError *err = nil;

    // Load metal shader library from disk
    NSURL *libURL = [NSURL fileURLWithPath:@"Shaders.metallib"];

    id<MTLLibrary> lib = [device newLibraryWithURL:libURL error:&err];
    if (!lib) {
        NSLog(@"Failed to load metallib: %@", err);
        return nil;
    }

    // Create compute pipeline state
    id<MTLFunction> cfn = [lib newFunctionWithName:@"nbody_kernel"];

    computePipelineState = [device newComputePipelineStateWithFunction:cfn error:&err];
    if (!computePipelineState) {
        NSLog(@"Failed to create compute pipeline state: %@", err);
        return nil;
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
    colorAttachment.alphaBlendOperation = MTLBlendOperationAdd;
    colorAttachment.destinationRGBBlendFactor = MTLBlendFactorOne;

    renderPipelineState = [device newRenderPipelineStateWithDescriptor:pdesc error:&err];
    if (!renderPipelineState) {
        NSLog(@"Failed to create render pipeline state: %@", err);
        return nil;
    }

    // Initialize buffers
    particleBuffer = [device newBufferWithLength:sizeof(Particle) * simParams.numParticles
                                         options:MTLResourceStorageModeShared];
    
    particleBufferNext = [device newBufferWithLength:sizeof(Particle) * simParams.numParticles
                                             options:MTLResourceStorageModeShared];
    
    uniformBuffer = [device newBufferWithLength:sizeof(Uniforms)
                                        options:MTLResourceStorageModeShared];

    [self initParticles];

    return self;
}

// Initialize particles
- (void)initParticles {
    Particle *particles = (Particle *)particleBuffer.contents;
    Particle *particlesNext = (Particle *)particleBufferNext.contents;

    float totalMass = 0.0f;

    for (int i=0;i<simParams.numParticles;++i) {
        // random in sphere radius r
        float r = cbrtf((float)rand() / RAND_MAX) * initial_radius;
        float theta = ((float)rand() / RAND_MAX) * 2.0f * M_PI;
        float phi = acosf(2.0f * ((float)rand() / RAND_MAX) - 1.0f);
        float x = r * sinf(phi) * cosf(theta);
        float y = r * sinf(phi) * sinf(theta);
        float z = r * cosf(phi);

        particles[i].pos = (simd_float3){x,y,z};
        particles[i].vel = (simd_float3){0,0,0};
        particles[i].color = (simd_float3){ (float)rand()/RAND_MAX, (float)rand()/RAND_MAX, (float)rand()/RAND_MAX };
        
        float mass = 1.0f;
        particles[i].mass = mass;
        totalMass += mass;

        particlesNext[i] = particles[i];
    }

    float invRadius3 = 1.0 / (initial_radius * initial_radius * initial_radius);
    simParams.expansionFactor = simParams.G * totalMass * invRadius3;
}

// Update eye vector and rebuild view matrix
- (void)updateEye {
    float cx = camRadius * cosf(camPitch) * sinf(camYaw);
    float cy = camRadius * sinf(camPitch);
    float cz = camRadius * cosf(camPitch) * cosf(camYaw);

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
    u.particleDisplaySize = particle_display_size;
    memcpy(uniformBuffer.contents, &u, sizeof(Uniforms));

    id<MTLCommandBuffer> cmd = [commandQueue commandBuffer];

    if (doSimStep) {
        // --- Compute pass ---
        
        // Swap buffers
        id<MTLBuffer> tmp = particleBuffer;
        particleBuffer = particleBufferNext;
        particleBufferNext = tmp;
        
        NSUInteger threadgroupSize = threadgroup_size;
        NSUInteger numThreadgroups = simParams.numParticles / threadgroupSize;

        MTLSize groupSize = MTLSizeMake(threadgroupSize, 1, 1);
        MTLSize numGroups = MTLSizeMake(numThreadgroups, 1, 1);

        id<MTLComputeCommandEncoder> cenc = [cmd computeCommandEncoder];

        [cenc setComputePipelineState:computePipelineState];
        [cenc setBuffer:particleBuffer offset:0 atIndex:0];
        [cenc setBuffer:particleBufferNext offset:0 atIndex:1];
        [cenc setBytes:&simParams length:sizeof(ComputeParams) atIndex:2];

        [cenc dispatchThreadgroups:numGroups threadsPerThreadgroup:groupSize];
        [cenc endEncoding];
    }

    // --- Render pass ---

    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    if (!rpd) return; // no drawable available

    id<MTLRenderCommandEncoder> renc = [cmd renderCommandEncoderWithDescriptor:rpd];
    [renc setRenderPipelineState:renderPipelineState];
    [renc setVertexBuffer:particleBuffer offset:0 atIndex:0];
    [renc setVertexBuffer:uniformBuffer offset:0 atIndex:1];
    [renc drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:simParams.numParticles];
    [renc endEncoding];

    [cmd presentDrawable:view.currentDrawable];
    [cmd commit];
}

@end