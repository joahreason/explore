extends Node2D

## Click-and-drag panning + scroll-wheel zoom for viewing the generated world.
## No character/physics involved - this node's position is just the camera
## anchor that ChunkManager streams chunks around.

@export var zoom_factor: float = 1.15  # multiplicative per scroll notch
@export var min_zoom: float = 0.2
@export var max_zoom: float = 6.0

@onready var camera: Camera2D = $Camera2D

var _dragging: bool = false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = event.pressed
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_set_zoom(camera.zoom.x * zoom_factor)
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_set_zoom(camera.zoom.x / zoom_factor)
	elif event is InputEventMouseMotion and _dragging:
		global_position -= event.relative / camera.zoom.x


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_dragging = false


func _set_zoom(value: float) -> void:
	var z := clampf(value, min_zoom, max_zoom)
	camera.zoom = Vector2(z, z)
