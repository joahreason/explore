extends Node2D

## Pan + zoom camera for viewing the generated world.
## Mouse: click-and-drag to pan, scroll wheel to zoom.
## Touch: one-finger drag to pan, two-finger pinch to zoom (pinching while
## the midpoint moves pans at the same time, like any map app).
## No character/physics involved - this node's position is just the camera
## anchor that ChunkManager streams chunks around.

@export var zoom_factor: float = 1.15  # multiplicative per scroll notch
@export var min_zoom: float = 0.2
@export var max_zoom: float = 6.0

## Below this much on-screen movement between press and release, a left
## click is treated as a tap (inspect the tile) rather than a pan.
const CLICK_DRAG_THRESHOLD := 6.0

## Emitted with the world-space position of a left click that wasn't a drag
## (see CLICK_DRAG_THRESHOLD) - chunk_manager.gd listens for this to drive
## the tile inspector panel.
signal clicked(world_pos: Vector2)

@onready var camera: Camera2D = $Camera2D

var _dragging: bool = false
var _press_position: Vector2 = Vector2.ZERO
var _touches: Dictionary = {}   # touch index -> last Vector2 position
var _touch_press_positions: Dictionary = {}  # touch index -> Vector2 at press
var _pinch_distance: float = 0.0


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion and _dragging:
		global_position -= event.relative / camera.zoom.x
	elif event is InputEventScreenTouch:
		_handle_touch(event)
	elif event is InputEventScreenDrag:
		_handle_touch_drag(event)


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		if event.pressed:
			_press_position = event.position
		elif event.position.distance_to(_press_position) < CLICK_DRAG_THRESHOLD:
			clicked.emit(get_global_mouse_position())
	elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
		_set_zoom(camera.zoom.x * zoom_factor)
	elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_set_zoom(camera.zoom.x / zoom_factor)


func _handle_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		_touches[event.index] = event.position
		_touch_press_positions[event.index] = event.position
	else:
		# Only a gesture that was a single finger for its whole duration
		# counts as a tap - a pinch collapsing down to one finger on release
		# should never trigger the tile inspector.
		var was_single_touch := _touches.size() == 1
		var press_position: Vector2 = _touch_press_positions.get(event.index, event.position)
		_touches.erase(event.index)
		_touch_press_positions.erase(event.index)
		if was_single_touch and event.position.distance_to(press_position) < CLICK_DRAG_THRESHOLD:
			clicked.emit(_screen_to_world(event.position))

	_pinch_distance = _current_pinch_distance() if _touches.size() == 2 else 0.0


func _handle_touch_drag(event: InputEventScreenDrag) -> void:
	if not _touches.has(event.index):
		return
	_touches[event.index] = event.position

	if _touches.size() == 1:
		global_position -= event.relative / camera.zoom.x
	elif _touches.size() == 2:
		var new_distance := _current_pinch_distance()
		if _pinch_distance > 0.0:
			_set_zoom(camera.zoom.x * (new_distance / _pinch_distance))
		_pinch_distance = new_distance
		# Each finger's drag contributes half - two fingers moving together
		# (pure pan) sums to the full translation; moving apart (pure pinch)
		# cancels out, so panning and pinching combine naturally.
		global_position -= event.relative / camera.zoom.x / 2.0


func _screen_to_world(screen_pos: Vector2) -> Vector2:
	return get_viewport().canvas_transform.affine_inverse() * screen_pos


func _current_pinch_distance() -> float:
	var positions := _touches.values()
	return (positions[0] - positions[1]).length()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_dragging = false
		_touches.clear()
		_touch_press_positions.clear()
		_pinch_distance = 0.0


func _set_zoom(value: float) -> void:
	var z := clampf(value, min_zoom, max_zoom)
	camera.zoom = Vector2(z, z)
