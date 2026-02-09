extends Node2D

const ComputePassScript = preload("res://compute_pass.gd")

# ==== Inspector: 基础参数 ====
@export_group("Settings")
@export_range(1, 1000, 1) var update_frequency: int = 60
@export var auto_start: bool = false
@export var data_texture: Texture2D
@export_range(1, 4096, 1) var grid_width: int = 64
@export_range(1, 256, 1) var compute_local_size: int = 32

# ==== Inspector: 资源引用 ====
@export_group("Requirements")
@export_file("*.glsl", "*.gdshader", "*.res") var compute_shader_path: String = "res://conwayCS.glsl"
@export var extra_compute_shader_paths: PackedStringArray = PackedStringArray()
@export_range(0, 64, 1) var active_compute_shader_index: int = 0
@export var renderer_path: NodePath = ^"Renderer"

# ==== 场景节点 ====
@onready var renderer: Sprite2D = get_node_or_null(renderer_path)

# ==== GPU 句柄（纹理 + RD 设备） ====
var rd: RenderingDevice
var input_texture: RID = RID()
var output_texture: RID = RID()
var compute_passes: Array = []

# ==== CPU 图像与显示资源 ====
var input_image: Image
var output_image: Image
var render_texture: ImageTexture
var input_format: RDTextureFormat
var output_format: RDTextureFormat

# ==== 运行时状态 ====
var pending_gpu_work: bool = false
var texture_usage: int = (
	RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
)


# ==== 生命周期 ====
func _ready() -> void:
	if renderer == null:
		push_error("Renderer node is missing. Check renderer_path in inspector.")
		return

	# 1) 准备 CPU 图像与材质贴图入口
	create_and_validate_images()

	# 2) 初始化 RD + 纹理 + 多个 ComputePass
	setup_compute_runtime()

	# 单步模式：可选自动执行一步
	if auto_start:
		step_once()


func _input(event: InputEvent) -> void:
	# Space: 手动执行一次 compute + render
	if event is InputEventKey and event.keycode == KEY_SPACE and event.pressed and not event.echo:
		step_once()


func _notification(what: int) -> void:
	# 关闭窗口或节点销毁时释放 GPU 资源
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		cleanup_gpu()


# ==== 单步执行 ====
func step_once() -> void:
	var active_pass: Object = get_active_compute_pass()
	if active_pass == null:
		push_warning("No compute pass is available.")
		return

	if not is_compute_ready():
		push_warning("Compute pipeline is not ready. Cannot step.")
		return

	update_compute(active_pass)
	render_compute()


func set_active_compute_shader(index: int) -> void:
	if compute_passes.is_empty():
		push_warning("No compute pass is available.")
		return
	active_compute_shader_index = int(clamp(index, 0, compute_passes.size() - 1))


func get_compute_shader_count() -> int:
	return compute_passes.size()


# ==== 图像初始化 ====
func create_and_validate_images() -> void:
	# 输出图：compute 写入目标
	output_image = Image.create(grid_width, grid_width, false, Image.FORMAT_RGBAF)

	# 输入图：优先用外部贴图，否则噪声初始化
	if data_texture == null:
		var noise := FastNoiseLite.new()
		noise.frequency = 0.1
		input_image = noise.get_image(grid_width, grid_width)
	else:
		input_image = data_texture.get_image()

	# compute shader 使用 rgba32f，对齐到 FORMAT_RGBAF
	if input_image.get_format() != Image.FORMAT_RGBAF:
		input_image.convert(Image.FORMAT_RGBAF)

	merge_images()
	link_output_texture_to_renderer()


func merge_images() -> void:
	# 把 input_image 居中拷贝到 output_image，再把 input 同步成同一份数据
	var output_width := output_image.get_width()
	var output_height := output_image.get_height()
	var input_width := input_image.get_width()
	var input_height := input_image.get_height()

	var start_x := int((output_width - input_width) / 2)
	var start_y := int((output_height - input_height) / 2)

	for y in range(input_height):
		for x in range(input_width):
			var color := input_image.get_pixel(x, y)
			var dest_x := start_x + x
			var dest_y := start_y + y
			if dest_x >= 0 and dest_x < output_width and dest_y >= 0 and dest_y < output_height:
				output_image.set_pixel(dest_x, dest_y, color)

	input_image = Image.create_from_data(
		output_width,
		output_height,
		false,
		Image.FORMAT_RGBAF,
		output_image.get_data()
	)


func link_output_texture_to_renderer() -> void:
	# binaryDataTexture 是显示 shader 的二值数据入口
	var mat := renderer.material as ShaderMaterial
	if mat == null:
		push_error("Renderer material must be a ShaderMaterial.")
		return

	render_texture = ImageTexture.create_from_image(output_image)
	mat.set_shader_parameter("binaryDataTexture", render_texture)
	mat.set_shader_parameter("gridWidth", grid_width)


# ==== Compute 运行时初始化 ====
func setup_compute_runtime() -> void:
	create_rendering_device()
	if rd == null:
		push_warning("Local RenderingDevice is unavailable. Compute step is disabled in this run.")
		return

	create_texture_formats()
	create_storage_textures()
	if not input_texture.is_valid() or not output_texture.is_valid():
		push_error("Failed to create storage textures.")
		cleanup_gpu()
		return

	create_compute_passes()
	if compute_passes.is_empty():
		push_error("No compute pass is ready.")
		cleanup_gpu()
		return

	active_compute_shader_index = int(clamp(active_compute_shader_index, 0, compute_passes.size() - 1))


func create_rendering_device() -> void:
	# 创建本地 RD，上面会记录/提交 compute 指令
	rd = RenderingServer.create_local_rendering_device()


func get_compute_shader_paths() -> PackedStringArray:
	var paths := PackedStringArray()
	if not compute_shader_path.is_empty():
		paths.append(compute_shader_path)

	for path in extra_compute_shader_paths:
		if not path.is_empty() and not paths.has(path):
			paths.append(path)

	return paths


func create_compute_passes() -> void:
	compute_passes.clear()
	var shader_paths := get_compute_shader_paths()

	for path in shader_paths:
		var compute_pass = ComputePassScript.new()
		if compute_pass.setup(rd, path, input_texture, output_texture):
			compute_passes.append(compute_pass)
		else:
			push_warning("Skipped compute pass: %s" % path)


func get_active_compute_pass():
	if compute_passes.is_empty():
		return null

	var clamped_index := int(clamp(active_compute_shader_index, 0, compute_passes.size() - 1))
	if clamped_index != active_compute_shader_index:
		active_compute_shader_index = clamped_index

	return compute_passes[active_compute_shader_index]


func default_texture_format() -> RDTextureFormat:
	# conwayCS.glsl 使用 layout(binding=*, rgba32f) image2D
	var fmt := RDTextureFormat.new()
	fmt.width = grid_width
	fmt.height = grid_width
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.usage_bits = texture_usage
	return fmt


func create_texture_formats() -> void:
	input_format = default_texture_format()
	output_format = default_texture_format()


func create_storage_texture(image: Image, format: RDTextureFormat) -> RID:
	var view := RDTextureView.new()
	var data: Array[PackedByteArray] = [image.get_data()]
	return rd.texture_create(format, view, data)


func create_storage_textures() -> void:
	input_texture = create_storage_texture(input_image, input_format)
	output_texture = create_storage_texture(output_image, output_format)


# ==== Compute + 渲染回读 ====
func update_compute(active_pass) -> void:
	if active_pass == null or not is_compute_ready():
		return

	# dispatch 的组数 = ceil(grid_width / local_size)
	var groups := int(ceil(float(grid_width) / float(max(compute_local_size, 1))))
	var compute_list := rd.compute_list_begin()
	active_pass.bind_for_dispatch(rd, compute_list)
	rd.compute_list_dispatch(compute_list, groups, groups, 1)
	rd.compute_list_end()
	rd.submit()
	pending_gpu_work = true


func render_compute() -> void:
	if not is_compute_ready() or render_texture == null:
		return

	# 等待 GPU 完成本次 dispatch，然后把 output 用作下一次 input
	rd.sync()
	pending_gpu_work = false
	var bytes := rd.texture_get_data(output_texture, 0)
	rd.texture_update(input_texture, 0, bytes)
	output_image.set_data(grid_width, grid_width, false, Image.FORMAT_RGBAF, bytes)
	render_texture.update(output_image)


# ==== 可用性判断 ====
func is_compute_ready() -> bool:
	var active_pass: Object = get_active_compute_pass()
	return (
		rd != null
		and input_texture.is_valid()
		and output_texture.is_valid()
		and active_pass != null
		and active_pass.has_method("is_ready")
		and bool(active_pass.call("is_ready"))
	)


# ==== 资源释放 ====
func cleanup_gpu() -> void:
	if rd == null:
		return

	if pending_gpu_work:
		rd.sync()
		pending_gpu_work = false

	for compute_pass in compute_passes:
		compute_pass.cleanup(rd)
	compute_passes.clear()

	if input_texture.is_valid():
		rd.free_rid(input_texture)
		input_texture = RID()
	if output_texture.is_valid():
		rd.free_rid(output_texture)
		output_texture = RID()

	rd.free()
	rd = null
