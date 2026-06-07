#import <MetalKit/MetalKit.h>
#import <simd/simd.h>
#import "Structs.m"
#import "MatrixUtils.m"
#include <iostream>
#include <iomanip>
#include <string>
#include <map>

@interface NBodySim : NSObject <MTKViewDelegate>
{
@public
    // Sim parameters
    int numParticles;
    std::string distributionType;
    double G, H0, Omega_m, Omega_l;
    double r_0, t_0, m_0;
    double zInit, deltaTime, radius, softening;
    double sim_m, sim_r, sim_dt, sim_ep2, sim_bg, sim_H0, sim_a;
    bool doSimStep;

    // Shaders
    int threadgroupSize;
    id<MTLDevice> device;
    id<MTLCommandQueue> commandQueue;
    id<MTLComputePipelineState> computePipelineState;
    id<MTLRenderPipelineState> renderPipelineState;
    id<MTLBuffer> particleBuffer;

    // Camera state
    float particleSize, particleAlpha;
    float camYaw, camPitch, camDist;
    simd_float3 eye;
    simd_float4x4 viewMatrix, projMatrix, mvp;
}

@end

@implementation NBodySim

- (instancetype)initWithView:(MTKView*)view
                  parameters:(std::map<std::string, std::string>)params {
    self = [super init];
    if (!self) return nil;

    // Constants (cgs)
    G = 6.674e-8;    // dyne cm^2 g^-2
    H0 = 2.268e-18;  // s^-1
    Omega_m = 0.3;
    Omega_l = 0.7;

    // Code units
    r_0 = 3.086e24;  // 1 Megaparsec
    t_0 = 3.154e13;  // 1 Megayear
    m_0 = r_0 * r_0 * r_0 / (G * t_0 * t_0);  // g

    // Sim parameters
    const int numParticlesDefault = 1 << 15;  // 32768
    const double zInitDefault = 30.0;
    const double deltaTimeDefault = 5.0;  // My
    const double radiusDefault = 1.0;  // Mpc
    const double softeningDefault = 0.1;
    const std::string distributionTypeDefault = std::string("ball");

    // Threadgroup size
    threadgroupSize = 128;

    // Display parameters
    particleSize = 20.0f;
    particleAlpha = 0.5f;
    
    auto getParam = [&](const std::string& key, auto defaultValue) {
        using T = std::decay_t<decltype(defaultValue)>;

        auto it = params.find("--" + key);
        if (it == params.end())
            return defaultValue;
        
        if constexpr (std::is_same_v<T, int>)
            return std::stoi(it->second);
        else if constexpr (std::is_same_v<T, double>)
            return std::stod(it->second);
        else if constexpr (std::is_same_v<T, std::string>)
            return it->second;
    };

    numParticles = getParam("N", numParticlesDefault);
    zInit = getParam("z", zInitDefault);
    deltaTime = getParam("dt", deltaTimeDefault) * t_0;
    radius = getParam("r", radiusDefault) * r_0;
    softening = getParam("soft", softeningDefault);
    distributionType = getParam("shape", distributionTypeDefault);

    [self initShaders: view];
    [self initSimState];
    [self initParticles];
    [self initCamera];

    doSimStep = false;
    return self;
}

- (void)drawInMTKView:(MTKView *)view {
    id<MTLCommandBuffer> cmd = [commandQueue commandBuffer];

    if (doSimStep) {
        SimState sims;
        sims.N = numParticles;
        sims.dt = sim_dt;
        sims.ep2 = sim_ep2;
        sims.bgField = sim_bg;

        // Update expansion factor
        auto adot = [&](double a) {
            return sim_H0 * sqrt(Omega_m / a + Omega_l * a * a);
        };

        double a_half = sim_a + 0.5 * sim_dt * adot(sim_a);
        double a_next = sim_a + sim_dt * adot(a_half);

        sims.a_prev = sim_a;
        sims.a_half = a_half;
        sims.a_next = a_next;
        sim_a = a_next;
        
        // --- Compute pass ---
        int numThreadgroups = numParticles / threadgroupSize;

        MTLSize groupSize = MTLSizeMake(threadgroupSize, 1, 1);
        MTLSize numGroups = MTLSizeMake(numThreadgroups, 1, 1);

        id<MTLComputeCommandEncoder> cenc = [cmd computeCommandEncoder];

        auto dispatchWithPass = [&](bool pass) {
            sims.isFirstPass = pass;
            [cenc setBytes:&sims length:sizeof(SimState) atIndex:1];
            [cenc dispatchThreadgroups:numGroups threadsPerThreadgroup:groupSize];
        };

        [cenc setComputePipelineState:computePipelineState];
        [cenc setBuffer:particleBuffer offset:0 atIndex:0];
        dispatchWithPass(true);
        id<MTLResource> resources[] = { particleBuffer };
        [cenc memoryBarrierWithResources:resources count:1];
        dispatchWithPass(false);
        [cenc endEncoding];
    }

    // --- Render pass ---
    projMatrix = getProjMatrix(60.0f * (M_PI/180.0f),
                               view.drawableSize.width/view.drawableSize.height,
                               0.01f, 100.0f);
    mvp = simd_mul(projMatrix, viewMatrix);

    CameraState cams;
    cams.mvp = mvp;
    cams.eye = eye;
    cams.pointSize = particleSize;
    cams.alpha = particleAlpha;

    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    if (!rpd) return;  // no drawable available

    id<MTLRenderCommandEncoder> renc = [cmd renderCommandEncoderWithDescriptor:rpd];
    [renc setRenderPipelineState:renderPipelineState];
    [renc setVertexBuffer:particleBuffer offset:0 atIndex:0];
    [renc setVertexBytes:&cams length:sizeof(CameraState) atIndex:1];
    [renc drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:numParticles];
    [renc endEncoding];

    [cmd presentDrawable:view.currentDrawable];
    [cmd commit];
}

- (void)initSimState {
    bool isSphere = distributionType == "ball";
    double volume = (isSphere ? 4/3.0 * M_PI : 8.0) * radius * radius * radius;
    double volumePerParticle = volume / numParticles;
    double epsilon2 = cbrt(volumePerParticle) * softening;

    double rho_crit = 3 * H0 * H0 / (8 * M_PI * G);
    double massPerParticle = rho_crit * volumePerParticle;

    // |dg/dr| due to uniform background
    double background = 4/3.0 * M_PI * G * rho_crit;
    
    // Code variables
    sim_m = massPerParticle / m_0;
    sim_r = radius / r_0;
    sim_dt = deltaTime / t_0;
    sim_ep2 = epsilon2 / r_0;
    sim_bg = background * t_0 * t_0;
    sim_H0 = H0 * t_0;
    sim_a = 1.0 / (1 + zInit);  // expansion factor
}

- (void)initParticles {
    const simd_float3 warm = (simd_float3){1.0f, 0.9f, 0.7f};
    const simd_float3 cool = (simd_float3){0.7f, 0.8f, 1.0f};
    const bool isSphere = distributionType == "ball";

    Particle *particles = (Particle *)particleBuffer.contents;

    for (int i=0; i<numParticles; ++i) {
        float x, y, z;

        if (isSphere) {
            // Uniform sphere
            double r = cbrt((double)rand() / RAND_MAX) * sim_r;
            double theta = ((double)rand() / RAND_MAX) * 2.0 * M_PI;
            double phi = acos(2.0 * ((double)rand() / RAND_MAX) - 1.0);
            x = r * sin(phi) * cos(theta);
            y = r * sin(phi) * sin(theta);
            z = r * cos(phi);
        } else {
            // Cube with side length 2r
            x = (2.0 * ((double)rand() / RAND_MAX) - 1.0) * sim_r;
            y = (2.0 * ((double)rand() / RAND_MAX) - 1.0) * sim_r;
            z = (2.0 * ((double)rand() / RAND_MAX) - 1.0) * sim_r;
        }

        particles[i].pos = (simd_float3){x, y, z};
        particles[i].mom = (simd_float3){0.0f, 0.0f, 0.0f};
        particles[i].acc = (simd_float3){0.0f, 0.0f, 0.0f};
        particles[i].mass = sim_m;

        double lerpFac = (double)rand() / RAND_MAX;
        particles[i].color = warm * lerpFac + cool * (1.0f - lerpFac);
    }
}

- (void)initShaders:(MTKView *)view {
    device = view.device;
    commandQueue = [device newCommandQueue];
    NSError *err = nil;
    
    // Load metal shader library from disk
    NSURL *libURL = [NSURL fileURLWithPath:@"Shaders.metallib"];

    id<MTLLibrary> lib = [device newLibraryWithURL:libURL error:&err];
    if (!lib) {
        NSLog(@"Failed to load metallib: %@", err);
        return;
    }

    // Create compute pipeline state
    id<MTLFunction> cfn = [lib newFunctionWithName:@"nbody_kernel"];

    computePipelineState = [device newComputePipelineStateWithFunction:cfn error:&err];
    if (!computePipelineState) {
        NSLog(@"Failed to create compute pipeline state: %@", err);
        return;
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
    colorAttachment.sourceRGBBlendFactor = MTLBlendFactorOne;
    colorAttachment.destinationRGBBlendFactor = MTLBlendFactorOne;

    renderPipelineState = [device newRenderPipelineStateWithDescriptor:pdesc error:&err];
    if (!renderPipelineState) {
        NSLog(@"Failed to create render pipeline state: %@", err);
        return;
    }

    // Create particle buffer
    particleBuffer = [device newBufferWithLength:sizeof(Particle) * numParticles
                                         options:MTLResourceStorageModeShared];
}

- (void)initCamera {
    camYaw = 0.0f;
    camPitch = 0.3f;
    camDist = 2.0f;
    [self updateEye];
}

- (void)updateEye {
    float cx = camDist * cosf(camPitch) * sinf(camYaw);
    float cy = camDist * sinf(camPitch);
    float cz = camDist * cosf(camPitch) * cosf(camYaw);

    eye = { cx, cy, cz };
    simd_float3 center = {0.0f, 0.0f, 0.0f};
    simd_float3 up = {0.0f, 1.0f, 0.0f};
    viewMatrix = getViewMatrix(eye, center, up);
}

- (void)printSimState {
    Particle *particles = (Particle *)particleBuffer.contents;
    simd_float3 p = (simd_float3){0.0f, 0.0f, 0.0f};
    float E = 0;

    for (int i=0; i<numParticles; ++i) {
        p += particles[i].mom;
        E += (particles[i].mom[0] * particles[i].mom[0] +
              particles[i].mom[1] * particles[i].mom[1] +
              particles[i].mom[2] * particles[i].mom[2]) / (2 * particles[i].mass);
    }

    p /= numParticles;
    E /= numParticles;

    float z = 1 / sim_a - 1;

    std::cout << std::fixed << std::setprecision(2);
    std::cout << "z="  << std::left  << std::setw(7)  << z
              << "p=[" << std::right << std::setw(5)  << p[0] 
              << ","   << std::right << std::setw(5)  << p[1] 
              << ","   << std::right << std::setw(5)  << p[2] 
              << "]  E=" << E << "\n";
}

- (void)toggleSim {
    doSimStep = !doSimStep;
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

@end