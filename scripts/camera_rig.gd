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

## Direct children of this node are treated as "UI" for _is_over_ui() below -
## a press/tap starting on one of them (or on a currently-open popup, e.g.
## the view-mode dropdown's list) is never treated as a map pan/tap. This is
## necessary because raw touch events (InputEventScreenTouch/Drag) are NOT
## consumed by Controls the way their emulated-mouse counterparts are - a
## tap on the dropdown or the inspector panel would otherwise ALSO reach
## this node's _unhandled_input as an unclaimed touch, corrupting pan/pinch
## state and firing a spurious tile-click under the UI. See world.tscn
## (ui_root_path wired to "../UI").
##
## project.godot has emulate_mouse_from_touch=true (needed so Controls like
## the dropdown/buttons/scrollbar respond to touch at all) - that means a
## touch on the open map ALSO arrives here as a parallel synthetic mouse
## press/motion/release. _handle_mouse_button ignores that mirror whenever a
## raw touch gesture is already being tracked in _touches, so a one-finger
## drag doesn't pan the camera twice (once per event stream).
@export var ui_root_path: NodePath

## Below this much on-screen movement between press and release, a left
## click is treated as a tap (inspect the tile) rather than a pan.
const CLICK_DRAG_THRESHOLD := 6.0

## Emitted with the world-space position of a left click that wasn't a drag
## (see CLICK_DRAG_THRESHOLD) - chunk_manager.gd listens for this to drive
## the tile inspector panel.
signal clicked(world_pos: Vector2)

@onready var camera: Camera2D = $Camera2D
@onready var _ui_root: Node = get_node(ui_root_path) if ui_root_path != NodePath() else null

var _dragging: bool = false
var _press_position: Vector2 = Vector2.ZERO
var _touches: Dictionary = {}   # touch index -> last Vector2 position
var _touch_press_positions: Dictionary = {}  # touch index -> Vector2 at press
var _touch_over_ui: Dictionary = {}  # touch index -> bool, was its press over UI
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


## True if a currently-hovered Control claims this point (best-effort - GUI
## hover tracking from touch isn't guaranteed to have updated yet by the
## time the parallel raw touch event reaches here), or if it falls inside
## one of _ui_root's own Control children, or if any dropdown's popup list
## is currently open (that popup lives outside _ui_root's children and can
## render anywhere on screen, so its open/closed state - not screen_pos -
## is what decides it: this makes the whole gesture that opened it, and any
## gesture while it stays open, unconditionally "over UI").
func _is_over_ui(screen_pos: Vector2) -> bool:
	if get_viewport().gui_get_hovered_control() != null:
		return true
	if _ui_root == null:
		return false
	for child in _ui_root.get_children():
		if child is OptionButton and child.get_popup().visible:
			return true
		if child is Control and child.visible and child.get_global_rect().has_point(screen_pos):
			return true
	return false


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			# Ignore both a press over UI (see _is_over_ui) and the
			# touch-emulated mirror of a raw touch gesture _handle_touch is
			# already tracking (see the emulate_mouse_from_touch note above).
			if _is_over_ui(event.position) or not _touches.is_empty():
				return
			_dragging = true
			_press_position = event.position
		elif _dragging:
			_dragging = false
			if event.position.distance_to(_press_position) < CLICK_DRAG_THRESHOLD:
				clicked.emit(get_global_mouse_position())
	elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
		_set_zoom(camera.zoom.x * zoom_factor)
	elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_set_zoom(camera.zoom.x / zoom_factor)


func _handle_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		var over_ui := _is_over_ui(event.position)
		_touch_over_ui[event.index] = over_ui
		if over_ui:
			return
		_touches[event.index] = event.position
		_touch_press_positions[event.index] = event.position
	else:
		var was_over_ui: bool = _touch_over_ui.get(event.index, false)
		_touch_over_ui.erase(event.index)
		if was_over_ui:
			_pinch_distance = _current_pinch_distance() if _touches.size() == 2 else 0.0
			return

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
	if _touch_over_ui.get(event.index, false):
		return
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
		_touch_over_ui.clear()
		_pinch_distance = 0.0


func _set_zoom(value: float) -> void:
	var z := clampf(value, min_zoom, max_zoom)
	camera.zoom = Vector2(z, z)
