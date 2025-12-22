#include <metal_stdlib>
using namespace metal;

struct Particle {
    float3 pos;
    float3 vel;
    float3 acc;
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
    float particleDisplaySize;
};

struct ComputeParams {
    uint numParticles;
    float deltaTime;
    float G;
    float epsilonSq;
    float expansionFactor;
};

kernel void nbody_kernel(device Particle *particles [[buffer(0)]],
                         device Particle *particlesNext [[buffer(1)]],
                         constant ComputeParams &params [[buffer(2)]],
                         uint pid [[thread_position_in_grid]]) {
    Particle p = particles[pid];
    float dt = params.deltaTime;

    particlesNext[pid].pos = p.pos + p.vel * dt + p.acc * dt * dt * 0.5;

    float3 new_acc = float3();
    for (uint i = 0; i < params.numParticles; ++i) {
        if (i == pid) continue;
        Particle other = particles[i];
        float3 r = other.pos - p.pos;
        float r2 = dot(r, r) + params.epsilonSq;
        float invr3 = 1.0 / (r2 * sqrt(r2));
        new_acc += params.G * other.mass * r * invr3;
    }

    new_acc += p.pos * params.expansionFactor;
    
    float3 new_vel = p.vel + (p.acc + new_acc) * dt * 0.5;
    particlesNext[pid].vel = new_vel;
    particlesNext[pid].acc = new_acc;
}

vertex VSOut particle_vertex(const device Particle *particles [[buffer(0)]],
                          constant Uniforms &U [[buffer(1)]],
                          uint vid [[vertex_id]])
{
    Particle p = particles[vid];
    float dist_to_eye = length(p.pos - U.eye);

    VSOut out;
    out.position = U.mvp * float4(p.pos, 1.0);
    out.color = float4(p.color, 1.0);
    out.pointSize = U.particleDisplaySize / dist_to_eye;
    return out;
}

fragment float4 particle_fragment(VSOut in [[stage_in]],
                                  float2 pointCoord [[point_coord]]) {
    float r = length(pointCoord - 0.5);
    if (r > 0.5) discard_fragment(); // circle mask
    
    float intensity = 1 - r*2;
    return in.color * intensity * 0.5;
}