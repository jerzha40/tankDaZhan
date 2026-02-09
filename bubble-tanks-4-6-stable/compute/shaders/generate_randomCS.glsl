#version 450

uniform float cell_size;

const int cell_size_a=32;
layout(local_size_x = cell_size_a, local_size_y = cell_size_a) in;

layout(binding=0,rgba32f) uniform image2D random;

uint hash_u32(uint x) {
    x ^= x >> 16;
    x *= 0x7feb352du;
    x ^= x >> 15;
    x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

float rand01(uvec2 p, uint seed) {
    uint x = p.x * 0x9e3779b9u ^ p.y * 0x85ebca6bu ^ seed;
    return (hash_u32(x) & 0x00FFFFFFu) / 16777216.0; // 0..1
}

void main()
{
    ivec2 Gp = ivec2(gl_GlobalInvocationID.xy);
    ivec2 Lp = ivec2(gl_LocalInvocationID.xy);
    ivec2 Wp = ivec2(gl_WorkGroupID.xy);
    float cl= rand01(Gp,23);
    cl= (cl>0.5)?1.0:0.0;
    imageStore(random, Gp, vec4(cl,cl,cl,1.0));
}
