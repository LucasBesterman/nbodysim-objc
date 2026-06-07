#include <metal_stdlib>
using namespace metal;

struct Particle {
    float3 pos;
    float3 mom;
    float3 acc;
    float mass;
    float3 color;
};

struct Vertex {
    float4 position [[position]];
    float4 color;
    float pointSize [[point_size]];
};

struct CameraState {
    float4x4 mvp;
    float3 eye;
    float pointSize;
    float alpha;
};

struct SimState {
    uint N;
    float dt;
    float ep2;
    float bgField;
    float a_prev;
    float a_half;
    float a_next;
    bool isFirstPass;
};

kernel void nbody_kernel(device Particle *particles [[buffer(0)]],
                         constant SimState &sim [[buffer(1)]],
                         uint pid [[thread_position_in_grid]]) {
    Particle p = particles[pid];

    // Pass 1
    if (sim.isFirstPass) {
        float3 mom_half = p.mom + 0.5 * sim.dt * p.acc / sim.a_prev;  // Kick 1
        float3 pos_next = p.pos + sim.dt * mom_half / (sim.a_half * sim.a_half);  // Drift
        particles[pid].pos = pos_next;
        particles[pid].mom = mom_half;
        return;
    }
    
    // Pass 2
    float3 acc = float3();
    for (uint i=0; i<sim.N; ++i) {
        if (i == pid) continue;
        Particle other = particles[i];
        float3 r = other.pos - p.pos;
        float r2 = dot(r, r) + sim.ep2;
        float inv = rsqrt(r2);
        float inv3 = inv * inv * inv;
        acc += other.mass * r * inv3;
    }

    acc += sim.bgField * p.pos;
    float3 mom_next = p.mom + 0.5 * sim.dt * acc / sim.a_next;  // Kick 2
    particles[pid].mom = mom_next;
    particles[pid].acc = acc;
}

vertex Vertex particle_vertex(const device Particle *particles [[buffer(0)]],
                              constant CameraState &cam [[buffer(1)]],
                              uint vid [[vertex_id]])
{
    Particle p = particles[vid];
    float dist_to_eye = length(p.pos - cam.eye);

    Vertex out;
    out.position = cam.mvp * float4(p.pos, 1.0);
    out.color = float4(p.color, 1.0) * cam.alpha;
    out.pointSize = cam.pointSize / dist_to_eye;
    return out;
}

fragment float4 particle_fragment(Vertex in [[stage_in]],
                                  float2 pointCoord [[point_coord]]) {
    float r = length(pointCoord - 0.5);
    if (r > 0.5) discard_fragment();  // circle mask
    
    float intensity = smoothstep(0.5, 0.0, r);
    intensity = pow(intensity, 2.0);
    return in.color * intensity;
}