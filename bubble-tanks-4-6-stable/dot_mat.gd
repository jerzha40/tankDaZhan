extends Node2D

const ComputePassScript = preload("res://compute_pass.gd")

@export_group("Compute")
@export_file("*.glsl", "*.gdshader", "*.res") var compute_shader_path: String = "res://conwayCS.glsl"
@export_file("*.glsl", "*.gdshader", "*.res") var copy_shader_path: String = "res://copyCS.glsl"
@export_range(1, 4096, 1) var grid_width: int = 64
@export_range(1, 256, 1) var compute_local_size: int = 32
@export var auto_run: bool = true
@export_range(0.01, 10.0, 0.01) var auto_step_interval_sec: float = 0.5
@export var run_once_on_ready: bool = false
@export var renderer_path: NodePath = ^"Renderer"

var rd: RenderingDevice
var main_compute_pass
var copy_compute_pass
var input_texture: RID = RID()
var output_texture: RID = RID()
var input_image: Image
var output_image: Image
var render_texture: ImageTexture

@onready var renderer: Sprite2D = get_node_or_null(renderer_path)

var pending_gpu_work: bool = false
var auto_step_accum: float = 0.0
var texture_usage: int = (
	RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
)


func _ready() -> void:
	if renderer == null:
		push_error("Renderer node is missing. Check renderer_path.")
		return

	create_images()
	setup_compute_passes()
	if output_image != null:
		link_output_texture_to_renderer()

	if run_once_on_ready and is_compute_ready():
		step_once()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.keycode == KEY_SPACE and event.pressed and not event.echo:
		step_once()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		cleanup_gpu()


func _process(delta: float) -> void:
	if not auto_run:
		return
	if not is_compute_ready():
		return

	auto_step_accum += delta
	var interval: float = float(max(auto_step_interval_sec, 0.01))
	while auto_step_accum >= interval:
		auto_step_accum -= interval
		step_once()


func setup_compute_passes() -> void:
	rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		push_warning("Local RenderingDevice is unavailable.")
		return

	create_storage_textures()
	if not input_texture.is_valid() or not output_texture.is_valid():
		push_error("Failed to create storage textures.")
		cleanup_gpu()
		return

	main_compute_pass = ComputePassScript.new()
	if not main_compute_pass.setup(rd, compute_shader_path, input_texture, output_texture):
		push_error("Main ComputePass setup failed: %s" % compute_shader_path)
		cleanup_gpu()
		return

	# copy pass: output -> input, replaces old CPU texture_update back-copy
	copy_compute_pass = ComputePassScript.new()
	if not copy_compute_pass.setup(rd, copy_shader_path, output_texture, input_texture):
		push_error("Copy ComputePass setup failed: %s" % copy_shader_path)
		cleanup_gpu()
		return

	print("Main ComputePass loaded shader:", compute_shader_path)
	print("Copy ComputePass loaded shader:", copy_shader_path)


func create_images() -> void:
	input_image = Image.create(grid_width, grid_width, false, Image.FORMAT_RGBAF)
	output_image = Image.create(grid_width, grid_width, false, Image.FORMAT_RGBAF)
	var noise := FastNoiseLite.new()
	noise.frequency = 0.1
	input_image = noise.get_image(grid_width, grid_width)
	if input_image.get_format() != Image.FORMAT_RGBAF:
		input_image.convert(Image.FORMAT_RGBAF)


func create_storage_textures() -> void:
	if rd == null:
		return
	if input_image == null or output_image == null:
		return

	var fmt := RDTextureFormat.new()
	fmt.width = grid_width
	fmt.height = grid_width
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.usage_bits = texture_usage

	var view := RDTextureView.new()
	var input_data: Array[PackedByteArray] = [input_image.get_data()]
	var output_data: Array[PackedByteArray] = [output_image.get_data()]

	input_texture = rd.texture_create(fmt, view, input_data)
	output_texture = rd.texture_create(fmt, view, output_data)


func link_output_texture_to_renderer() -> void:
	var mat := renderer.material as ShaderMaterial
	if mat == null:
		push_error("Renderer material must be ShaderMaterial.")
		return

	render_texture = ImageTexture.create_from_image(output_image)
	mat.set_shader_parameter("binaryDataTexture", render_texture)
	mat.set_shader_parameter("gridWidth", grid_width)


func step_once() -> void:
	if not is_compute_ready():
		push_warning("Compute passes are not ready.")
		return

	var groups := int(ceil(float(grid_width) / float(max(compute_local_size, 1))))
	var compute_list := rd.compute_list_begin()

	# 1) main: input -> output
	main_compute_pass.bind_for_dispatch(rd, compute_list)
	rd.compute_list_dispatch(compute_list, groups, groups, 1)
	# Ensure writes from main pass are visible before copy pass reads output texture.
	if rd.has_method("compute_list_add_barrier"):
		rd.call("compute_list_add_barrier", compute_list)

	# 2) copy: output -> input (GPU copy, replaces CPU round-trip copy)
	copy_compute_pass.bind_for_dispatch(rd, compute_list)
	rd.compute_list_dispatch(compute_list, groups, groups, 1)
	rd.compute_list_end()
	rd.submit()
	pending_gpu_work = true

	rd.sync ()
	pending_gpu_work = false
	var bytes := rd.texture_get_data(output_texture, 0)
	output_image.set_data(grid_width, grid_width, false, Image.FORMAT_RGBAF, bytes)
	if render_texture != null:
		render_texture.update(output_image)

	var live_count := count_live_cells(bytes)
	print("Pair step done (compute+copy). live=", live_count, " / ", grid_width * grid_width)


func is_compute_ready() -> bool:
	return (
		rd != null
		and main_compute_pass != null
		and main_compute_pass.has_method("is_ready")
		and bool(main_compute_pass.call("is_ready"))
		and copy_compute_pass != null
		and copy_compute_pass.has_method("is_ready")
		and bool(copy_compute_pass.call("is_ready"))
		and input_texture.is_valid()
		and output_texture.is_valid()
	)


func cleanup_gpu() -> void:
	if rd == null:
		return

	if pending_gpu_work:
		rd.sync ()
		pending_gpu_work = false

	if main_compute_pass != null:
		main_compute_pass.cleanup(rd)
		main_compute_pass = null

	if copy_compute_pass != null:
		copy_compute_pass.cleanup(rd)
		copy_compute_pass = null

	if input_texture.is_valid():
		rd.free_rid(input_texture)
		input_texture = RID()
	if output_texture.is_valid():
		rd.free_rid(output_texture)
		output_texture = RID()

	rd.free()
	rd = null


func count_live_cells(bytes: PackedByteArray) -> int:
	# FORMAT_RGBAF: each pixel = 4 floats = 16 bytes. R channel is first float.
	var live := 0
	var pixel_count := grid_width * grid_width
	for i in range(pixel_count):
		var offset := i * 16
		if offset + 3 >= bytes.size():
			break
		var r := bytes.decode_float(offset)
		if r > 0.5:
			live += 1
	return live
