typedef struct {
    simd_float3 pos;
    simd_float3 vel;
    simd_float3 color;
    float mass;
} Particle;

typedef struct {
    simd_float4x4 mvp;
    simd_float3 eye;
    float vertSize;
} Uniforms;

typedef struct {
    uint32_t N;
    float dt;
    float ep2;
    float H;
    float a_inv3;
} ComputeParams;