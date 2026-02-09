extends SceneTree

var dot_mat: Node

func _initialize() -> void:
	var packed := load("res://dot_mat.tscn") as PackedScene
	if packed == null:
		push_error("Failed to load dot_mat.tscn")
		quit(1)
		return

	dot_mat = packed.instantiate()
	root.add_child(dot_mat)
	call_deferred("_run")

func _run() -> void:
	await process_frame
	var key_event := InputEventKey.new()
	key_event.keycode = KEY_SPACE
	key_event.pressed = true
	key_event.echo = false
	dot_mat._input(key_event)
	print("space_step_triggered=true")
	await process_frame
	quit()
