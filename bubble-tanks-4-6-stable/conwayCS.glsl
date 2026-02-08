#[compute]
#version 450

const int grid_width = 64;

const vec4 live_color = vec4(0.0, 1.0, 0.0, 1.0);
const vec4 dead_color = vec4(1.0, 0.0, 0.0, 1.0);

layout(local_size_x = 32, local_size_y = 32) in;

layout(binding=0,rgba32f) uniform image2D input_world;
layout(binding=1,rgba32f) uniform image2D ouput_world;

bool is_cell_alive(int x, int y)
{
    vec4 a = imageLoad(input_world, ivec2(x, y));
    return a.r >= 0.5;
}

int get_live_neighbors(int x, int y)
{
    int count = 0;
    for (int i = -1; i <= 1; i++)
    {
        for (int j = -1; j <= 1; j++)
        {
            if (x == 0 && y == 0)
            {
                continue;
            }
            int nx = x + i;
            int ny = y + j;
            if (nx >= 0 && nx < grid_width && ny >= 0 && ny < grid_width)
            {
                count += int(is_cell_alive(nx, ny));
            }
        }
    }
	return count;
}

void main()
{
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    if (p.x >= grid_width || p.y >= grid_width)
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

    imageStore(ouput_world, p, new_color);
}
