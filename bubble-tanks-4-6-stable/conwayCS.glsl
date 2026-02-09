#[compute]
#version 450

const vec4 live_color = vec4(1.0, 0.0, 0.0, 1.0);
const vec4 dead_color = vec4(0.0, 0.0, 0.0, 1.0);

layout(local_size_x = 32, local_size_y = 32) in;

layout(binding=0,rgba32f) uniform image2D input_world;
layout(binding=1,rgba32f) uniform image2D output_world;

bool is_cell_alive(int x, int y)
{
    vec4 a = imageLoad(input_world, ivec2(x, y));
    return a.r >= 0.5;
}

int get_live_neighbors(int x, int y)
{
    ivec2 world_size = imageSize(input_world);
    int count = 0;
    for (int i = -1; i <= 1; i++)
    {
        for (int j = -1; j <= 1; j++)
        {
            if (i == 0 && j == 0)
            {
                continue;
            }
            int nx = x + i;
            int ny = y + j;
            if (nx >= 0 && nx < world_size.x && ny >= 0 && ny < world_size.y)
            {
                count += int(is_cell_alive(nx, ny));
            }
        }
    }
	return count;
}

void main()
{
    ivec2 world_size = imageSize(input_world);
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    if (p.x >= world_size.x || p.y >= world_size.y)
    {
        return;
    }
    int live_neighbors = get_live_neighbors(p.x, p.y);
    bool is_alive = is_cell_alive(p.x, p.y);
    bool next_state = is_alive;
    if (is_alive && (live_neighbors < 2 || live_neighbors > 3))
    {
        next_state = false;
    }
    else if (!is_alive && live_neighbors == 3)
    {
        next_state = true;
    }

    vec4 new_color = next_state ? live_color : dead_color;

    imageStore(output_world, p, new_color);
}
