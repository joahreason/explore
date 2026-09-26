extends ColorRect

## Drifting cloud shadows (polish): a rect kept over the camera's view (plus
## a margin) whose shader (shaders/cloud_shadows.gdshader) draws soft
## shadows from noise over world position, drifting with the wind
## (ChunkManager.wind / Wind.direction_at) at CLOUD_SPEED tiles per real
## second x the clock rate (capped like the sway animation: paused = still).
## Only in the views the day/night cycle tints (World, Terrain Only).

const CLOUD_SPEED := 0.6
const MARGIN := 64.0

var offset := Vector2.ZERO

@onready var _world := get_parent()
@onready var _camera: Camera2D = get_node("../CameraRig/Camera2D")


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	material = ShaderMaterial.new()
	material.shader = preload("res://shaders/cloud_shadows.gdshader")
	preload("res://scripts/game_constants.gd").apply_to(material)


func _process(delta: float) -> void:
	visible = _world.is_time_tinted_view()
	var rate := clampf(_world.clock.rate(), -Wind.MAX_ANIMATION_RATE, Wind.MAX_ANIMATION_RATE)
	offset += Wind.direction_at(_world.clock.minutes) * CLOUD_SPEED * delta * rate
	if not visible:
		return
	var view := get_viewport_rect().size / _camera.zoom
	var center := _camera.get_screen_center_position()
	position = center - view * 0.5 - Vector2.ONE * MARGIN
	size = view + Vector2.ONE * MARGIN * 2.0
	(material as ShaderMaterial).set_shader_parameter("offset", offset)
