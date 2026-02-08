#version 430
layout(local_size_x = 32, local_size_y = 32) in;

writeonly uniform iimage2D img_output;

void main()
{
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    ivec2 pp = ivec2(gl_LocalInvocationID.xy);
    imageStore(img_output, p, ivec4(pp * 255 / (31), 1.0, 1.0));
}
