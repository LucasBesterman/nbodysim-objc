typedef struct {
    simd_float3 pos;
    simd_float3 vel;
    simd_float3 acc;
    simd_float3 color;
    float mass;
} Particle;

typedef struct {
    simd_float4x4 mvp;
    simd_float3 eye;
    float particleDisplaySize;
} Uniforms;

typedef struct {
    uint32_t numParticles;
    float deltaTime;
    float G;
    float epsilonSq;
    float expansionFactor;
} ComputeParams;