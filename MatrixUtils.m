#import <simd/simd.h>

// Right-handed view matrix from look-at
static inline simd_float4x4 getViewMatrix(simd_float3 eye,
                                          simd_float3 center,
                                          simd_float3 up)
{
    simd_float3 z = simd_normalize(eye - center);      // Forward
    simd_float3 x = simd_normalize(simd_cross(up, z)); // Right
    simd_float3 y = simd_cross(z, x);                  // Up

    simd_float4 col0 = { x.x, y.x, z.x, 0.0f };
    simd_float4 col1 = { x.y, y.y, z.y, 0.0f };
    simd_float4 col2 = { x.z, y.z, z.z, 0.0f };
    simd_float4 col3 = { -simd_dot(x, eye),
                         -simd_dot(y, eye),
                         -simd_dot(z, eye),
                         1.0f };

    simd_float4x4 M = { col0, col1, col2, col3 };
    return M;
}

// Right-handed perspective projection matrix
static inline simd_float4x4 getProjectionMatrix(float fovyRadians,
                                                float aspect,
                                                float nearZ,
                                                float farZ)
{
    float yScale = 1.0f / tanf(fovyRadians * 0.5f);
    float xScale = yScale / aspect;
    float zRange = farZ - nearZ;

    simd_float4 col0 = { xScale, 0.0f,   0.0f,                    0.0f };
    simd_float4 col1 = { 0.0f,   yScale, 0.0f,                    0.0f };
    simd_float4 col2 = { 0.0f,   0.0f,   -(farZ+nearZ)/zRange,   -1.0f };
    simd_float4 col3 = { 0.0f,   0.0f,   -2.0f*farZ*nearZ/zRange, 0.0f };

    simd_float4x4 P = { col0, col1, col2, col3 };
    return P;
}
