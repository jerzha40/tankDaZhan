extends Node2D

const LOCAL_SIZE_X := 32
const LOCAL_SIZE_Y := 32

@export var compute_shader_path: String = "res://conwayCS.glsl"
@export var grid_width: int = 64
@export_range(0.0, 1.0, 0.01) var initial_alive_chance: float = 0.35

@onready var renderer: Sprite2D = $Renderer

var rd: RenderingDevice
var shader_rid: RID
var pipeline_rid: RID
var texture_a: RID
var texture_b: RID
var uniform_set_ab: RID
var uniform_set_ba: RID
var display_texture: ImageTexture
var use_a_as_input := true


func _ready() -> void:
    if not _setup_compute():
        set_process(false)
        return
    set_process(true)


func _process(_delta: float) -> void:
    var uniform_set := uniform_set_ab if use_a_as_input else uniform_set_ba
    var output_texture := texture_b if use_a_as_input else texture_a

    var compute_list := rd.compute_list_begin()
    rd.compute_list_bind_compute_pipeline(compute_list, pipeline_rid)
    rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
    rd.compute_list_dispatch(
        compute_list,
        _groups_for(grid_width, LOCAL_SIZE_X),
        _groups_for(grid_width, LOCAL_SIZE_Y),
        1
    )
    rd.compute_list_end()

    rd.submit()
    rd.sync()

    _update_display_texture(output_texture)
    use_a_as_input = not use_a_as_input


func _exit_tree() -> void:
    if rd == null:
        return
    _free_rd_resource(uniform_set_ab)
    _free_rd_resource(uniform_set_ba)
    _free_rd_resource(texture_a)
    _free_rd_resource(texture_b)
    _free_rd_resource(pipeline_rid)
    _free_rd_resource(shader_rid)
    rd.free()
    rd = null


func _setup_compute() -> bool:
    var material := renderer.material as ShaderMaterial
    if material == null:
        push_error("Renderer.material must be a ShaderMaterial.")
        return false

    rd = RenderingServer.create_local_rendering_device()
    if rd == null:
        push_error("Failed to create local RenderingDevice. Use Forward+ renderer.")
        return false

    var shader_file := load(compute_shader_path) as RDShaderFile
    if shader_file == null:
        push_error("Failed to load compute shader: %s" % compute_shader_path)
        return false

    shader_rid = rd.shader_create_from_spirv(shader_file.get_spirv())
    if not shader_rid.is_valid():
        push_error("Failed to create shader from SPIR-V.")
        return false

    pipeline_rid = rd.compute_pipeline_create(shader_rid)
    if not pipeline_rid.is_valid():
        push_error("Failed to create compute pipeline.")
        return false

    randomize()
    var texture_format := RDTextureFormat.new()
    texture_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
    texture_format.width = grid_width
    texture_format.height = grid_width
    texture_format.depth = 1
    texture_format.array_layers = 1
    texture_format.mipmaps = 1
    texture_format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
    texture_format.usage_bits = (
        RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
        | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
        | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
    )

    var texture_view := RDTextureView.new()
    var initial_bytes := _build_initial_world_bytes()

    texture_a = rd.texture_create(texture_format, texture_view, [initial_bytes])
    texture_b = rd.texture_create(texture_format, texture_view, [initial_bytes])
    if not texture_a.is_valid() or not texture_b.is_valid():
        push_error("Failed to create compute textures.")
        return false

    uniform_set_ab = _create_uniform_set(texture_a, texture_b)
    uniform_set_ba = _create_uniform_set(texture_b, texture_a)
    if not uniform_set_ab.is_valid() or not uniform_set_ba.is_valid():
        push_error("Failed to create compute uniform sets.")
        return false

    material.set_shader_parameter("gridWidth", grid_width)
    _update_display_texture(texture_a)
    return true


func _create_uniform_set(input_texture: RID, output_texture: RID) -> RID:
    var input_uniform := RDUniform.new()
    input_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
    input_uniform.binding = 0
    input_uniform.add_id(input_texture)

    var output_uniform := RDUniform.new()
    output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
    output_uniform.binding = 1
    output_uniform.add_id(output_texture)

    return rd.uniform_set_create([input_uniform, output_uniform], shader_rid, 0)


func _update_display_texture(texture: RID) -> void:
    var bytes := rd.texture_get_data(texture, 0)
    var image := Image.create_from_data(grid_width, grid_width, false, Image.FORMAT_RGBAF, bytes)

    if display_texture == null:
        display_texture = ImageTexture.create_from_image(image)
    else:
        display_texture.update(image)

    var material := renderer.material as ShaderMaterial
    if material != null:
        material.set_shader_parameter("binaryDataTexture", display_texture)


func _build_initial_world_bytes() -> PackedByteArray:
    var cell_count := grid_width * grid_width
    var data := PackedFloat32Array()
    data.resize(cell_count * 4)

    for i in range(cell_count):
        var base := i * 4
        var alive := randf() < initial_alive_chance
        data[base] = 1.0 if alive else 0.0
        data[base + 1] = 0.0
        data[base + 2] = 0.0
        data[base + 3] = 1.0

    return data.to_byte_array()


func _groups_for(size: int, local_size: int) -> int:
    return int(ceil(float(size) / float(local_size)))


func _free_rd_resource(resource: RID) -> void:
    if resource.is_valid():
        rd.free_rid(resource)
