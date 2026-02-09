extends RefCounted
class_name ComputePass

var shader_path: String = ""
var shader: RID = RID()
var pipeline: RID = RID()
var uniform_set: RID = RID()


func setup(rd: RenderingDevice, p_shader_path: String, input_texture: RID, output_texture: RID) -> bool:
	shader_path = p_shader_path

	if shader_path.is_empty():
		push_error("compute shader path is empty.")
		return false

	var shader_file := load(shader_path)
	if shader_file == null or not (shader_file is RDShaderFile):
		push_error("Failed to load RDShaderFile: %s" % shader_path)
		return false

	var spirv = shader_file.get_spirv()
	shader = rd.shader_create_from_spirv(spirv)
	if not shader.is_valid():
		push_error("shader_create_from_spirv failed for: %s" % shader_path)
		return false

	pipeline = rd.compute_pipeline_create(shader)
	if not pipeline.is_valid():
		push_error("compute_pipeline_create failed for: %s" % shader_path)
		cleanup(rd)
		return false

	var bindings: Array[RDUniform] = []

	var input_uniform := RDUniform.new()
	input_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	input_uniform.binding = 0
	input_uniform.add_id(input_texture)
	bindings.append(input_uniform)

	var output_uniform := RDUniform.new()
	output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	output_uniform.binding = 1
	output_uniform.add_id(output_texture)
	bindings.append(output_uniform)

	uniform_set = rd.uniform_set_create(bindings, shader, 0)
	if not uniform_set.is_valid():
		push_error("uniform_set_create failed for: %s" % shader_path)
		cleanup(rd)
		return false

	return true


func is_ready() -> bool:
	return shader.is_valid() and pipeline.is_valid() and uniform_set.is_valid()


func bind_for_dispatch(rd: RenderingDevice, compute_list: int) -> void:
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)


func cleanup(rd: RenderingDevice) -> void:
	if rd == null:
		return

	if uniform_set.is_valid():
		rd.free_rid(uniform_set)
		uniform_set = RID()
	if pipeline.is_valid():
		rd.free_rid(pipeline)
		pipeline = RID()
	if shader.is_valid():
		rd.free_rid(shader)
		shader = RID()
