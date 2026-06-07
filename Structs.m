typedef struct {
    simd_float3 pos;
    simd_float3 mom;
    simd_float3 acc;
    float mass;
    simd_float3 color;
} Particle;

typedef struct {
    simd_float4x4 mvp;
    simd_float3 eye;
    float pointSize;
    float alpha;
} CameraState;

typedef struct {
    uint32_t N;
    float dt;
    float ep2;
    float bgField;
    float a_prev;
    float a_half;
    float a_next;
    bool isFirstPass;
} SimState;