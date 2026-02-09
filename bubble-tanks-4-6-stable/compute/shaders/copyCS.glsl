#version 450

const int cell_size_a=32;
layout(local_size_x = cell_size_a, local_size_y = cell_size_a) in;

layout(binding=0,rgba32f) uniform image2D input_world;
layout(binding=1,rgba32f) uniform image2D output_world;

void main()
{
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);

    vec4 a = imageLoad(input_world, p);

    imageStore(output_world, p, a);
}
