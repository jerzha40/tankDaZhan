#version 450

layout(binding=0,rgba32f) uniform image2D random;
uniform float cell_size;

const int cell_size_a=1;

layout(local_size_x = cell_size_a, local_size_y = cell_size_a) in;


void main()
{
    ivec2 Gp = ivec2(gl_GlobalInvocationID.xy);
    ivec2 Lp = ivec2(gl_LocalInvocationID.xy);
    ivec2 Wp = ivec2(gl_WorkGroupID.xy);
    imageStore(random, Gp, vec4(Lp/3.0,cell_size,1.0));
}
