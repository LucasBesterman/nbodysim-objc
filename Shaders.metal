#include <metal_stdlib>
using namespace metal;

struct Particle {
    float3 pos;
    float3 vel;
    float3 color;
    float mass;
};

struct VSOut {
    float4 position [[position]];
    float4 color;
    float pointSize [[point_size]];
};

struct Uniforms {
    float4x4 mvp;
    float3 eye;
    float vertSize;
};

struct ComputeParams {
    uint N;
    float dt;
    float ep2;
    float H;
    float a_inv3;
};

kernel void nbody_kernel(device Particle *particles [[buffer(0)]],
                         device Particle *particlesNext [[buffer(1)]],
                         constant ComputeParams &params [[buffer(2)]],
                         uint pid [[thread_position_in_grid]]) {
    Particle p = particles[pid];

    float3 acc = float3();
    for (uint i = 0; i < params.N; ++i) {
        if (i == pid) continue;
        Particle other = particles[i];
        float3 r = other.pos - p.pos;
        float r2 = dot(r, r) + params.ep2;
        acc += other.mass * r / (r2 * sqrt(r2));
    }

    acc = acc * params.a_inv3 - 2 * params.H * p.vel;

    float3 vel_half = p.vel + acc * params.dt * 0.5f;  // Kick
    float3 pos_next = p.pos + vel_half * params.dt;  // Drift
    float3 vel_next = vel_half + acc * params.dt / 2; // Kick

    particlesNext[pid].pos = pos_next;
    particlesNext[pid].vel = vel_next;
}

float hash(uint x) {
    x ^= x >> 16;
    x *= 0x7feb352d;
    x ^= x >> 15;
    x *= 0x846ca68b;
    x ^= x >> 16;
    return float(x) / float(0xffffffff);
}

vertex VSOut particle_vertex(const device Particle *particles [[buffer(0)]],
                          constant Uniforms &U [[buffer(1)]],
                          uint vid [[vertex_id]])
{
    Particle p = particles[vid];
    float dist_to_eye = length(p.pos - U.eye);

    VSOut out;
    out.position = U.mvp * float4(p.pos, 1.0);

    float3 warm = float3(1.0, 0.9, 0.7);
    float3 cool = float3(0.7, 0.8, 1.0);
    out.color = float4(mix(warm, cool, hash(vid)) * p.color, 1.0);
    
    out.pointSize = U.vertSize / (0.2 + dist_to_eye);
    return out;
}

fragment float4 particle_fragment(VSOut in [[stage_in]],
                                  float2 pointCoord [[point_coord]]) {
    float r = length(pointCoord - 0.5);
    if (r > 0.5) discard_fragment(); // circle mask
    
    float intensity = smoothstep(0.5, 0.0, r);
    intensity = pow(intensity, 2.0);
    return in.color * intensity;
}