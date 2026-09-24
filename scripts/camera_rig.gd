extends Node2D

## Pan + zoom camera for viewing the generated world.
## Mouse: click-and-drag to pan, scroll wheel to zoom; a left click (not a
## drag) harvests, a right click shows tile/resource info (Phase 16).
## Touch: one-finger drag to pan, two-finger pinch to zoom (pinching while
## the midpoint moves pans at the same time, like any map app); a tap
## harvests, a long press (LONG_PRESS_SEC, finger still) shows info.
## No character/physics involved - this node's position is just the camera
## anchor that ChunkManager streams chunks around.

const SeedReloadScript := preload("res://scripts/seed_reload.gd")

@export var zoom_factor: float = 1.15  # multiplicative per scroll notch
## Polish: a flicked pan keeps gliding after release, slowing by
## MOMENTUM_DECAY per second (exponential); a drag that had stopped before
## release doesn't glide. Tests of exact pan distances turn it off.
@export var momentum: bool = true
const MOMENTUM_DECAY := 6.0
## Below this speed (world px / s) a glide stops, and a release starts none.
const MOMENTUM_MIN_SPEED := 20.0
## Drag motion older than this at release doesn't count towards the flick.
const MOMENTUM_WINDOW_MSEC := 80
## Wheel zoom eases towards its target at this rate (per second).
const ZOOM_EASE := 14.0
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
## the dropdown/buttons/scrollbar respond to touch at all) - that means the
## first finger on the map ALSO arrives here as a synthetic mouse
## press/motion/release, and Godot dispatches that mirror BEFORE the touch
## event itself. _unhandled_input drops every emulated mouse event (device
## InputEvent.DEVICE_ID_EMULATION) so touches are handled once, by the touch
## path; checking "is a touch already tracked" at the mouse press could never
## work, since the touch isn't recorded yet then - it made one-finger drags
## pan twice as far and let the first finger pan the camera again during a
## pinch (the sporadic jumps).
@export var ui_root_path: NodePath

## Below this much on-screen movement between press and release, a left
## click is treated as a tap (harvest) rather than a pan.
const CLICK_DRAG_THRESHOLD := 6.0
## A single finger held this long without moving is a long press (info)
## instead of a tap - touch screens have no right click.
const LONG_PRESS_SEC := 0.5

## World-space position of a left click / tap that wasn't a drag (see
## CLICK_DRAG_THRESHOLD): chunk_manager.gd harvests the resource there.
signal harvest_clicked(world_pos: Vector2)
## World-space position of a right click / long press: chunk_manager.gd
## shows the tile inspector panel for it.
signal info_clicked(world_pos: Vector2)

@onready var camera: Camera2D = $Camera2D
@onready var _ui_root: Node = get_node(ui_root_path) if ui_root_path != NodePath() else null

var _dragging: bool = false
## Current glide velocity (world px / s) and the recent drag samples
## [msec, world delta] it is measured from.
var _glide := Vector2.ZERO
var _drag_samples: Array = []
## Wheel zoom target (eased towards in _process); <= 0 = none pending.
var _zoom_target: float = -1.0
var _press_position: Vector2 = Vector2.ZERO
var _touches: Dictionary = {}   # touch index -> last Vector2 position
var _touch_press_positions: Dictionary = {}  # touch index -> Vector2 at press
var _touch_over_ui: Dictionary = {}  # touch index -> bool, was its press over UI
var _touch_press_msec: Dictionary = {}  # touch index -> Time.get_ticks_msec() at press
## Touches whose next drag only re-baselines their position (no pan / zoom):
## set for every remaining finger whenever the finger count changes, so
## lifting one finger of a pinch never moves the camera.
var _settle: Dictionary = {}
## The current single-finger gesture already fired its long press, so its
## release is not also a tap.
var _long_press_fired: bool = false
var _pinch_distance: float = 0.0
var _pinch_midpoint: Vector2 = Vector2.ZERO  # screen position between the two fingers
## True once a second finger joined the current gesture, until every finger
## lifts: the last finger of a pinch lifting near where it started is not a
## tap.
var _multi_touch: bool = false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION:
		return  # a touch's mouse mirror - see the emulate_mouse_from_touch note above
	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion and _dragging:
		_pan_by(-event.relative / camera.zoom.x)
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
		# Mouse-ignoring Controls (the position readout) don't block the map.
		if child is Control and child.visible and child.mouse_filter != Control.MOUSE_FILTER_IGNORE and child.get_global_rect().has_point(screen_pos):
			return true
	return false


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if _is_over_ui(event.position):
				return
			SeedReloadScript.close_keyboard(self)
			_stop_glide()
			_dragging = true
			_press_position = event.position
		elif _dragging:
			_dragging = false
			if event.position.distance_to(_press_position) < CLICK_DRAG_THRESHOLD:
				harvest_clicked.emit(get_global_mouse_position())
			else:
				_start_glide()
	elif event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed and not _is_over_ui(event.position):
			info_clicked.emit(get_global_mouse_position())
	elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
		_ease_zoom(zoom_factor)
	elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_ease_zoom(1.0 / zoom_factor)


func _handle_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		var over_ui := _is_over_ui(event.position)
		_touch_over_ui[event.index] = over_ui
		if over_ui:
			return
		# A tap on the map closes the on-screen keyboard (seed field).
		SeedReloadScript.close_keyboard(self)
		_stop_glide()
		_touches[event.index] = event.position
		_touch_press_positions[event.index] = event.position
		_touch_press_msec[event.index] = Time.get_ticks_msec()
		if _touches.size() > 1:
			_multi_touch = true
		else:
			_long_press_fired = false
	else:
		var was_over_ui: bool = _touch_over_ui.get(event.index, false)
		_touch_over_ui.erase(event.index)
		if was_over_ui:
			_reset_pinch()
			return
		# Browsers may report a lifted finger under a different index than it
		# was pressed with: release the tracked finger nearest to it.
		if not _touches.has(event.index) and not _touches.is_empty():
			_adopt_index(_nearest_touch(event.position), event.index)

		# Only a gesture that was a single finger for its whole duration
		# counts as a tap - a pinch collapsing down to one finger on release
		# should never trigger the tile inspector.
		var was_single_touch := _touches.size() == 1 and not _multi_touch
		var press_position: Vector2 = _touch_press_positions.get(event.index, event.position)
		_touches.erase(event.index)
		_touch_press_positions.erase(event.index)
		_touch_press_msec.erase(event.index)
		_settle.erase(event.index)
		if _touches.is_empty():
			_multi_touch = false
		if was_single_touch and not _long_press_fired and event.position.distance_to(press_position) < CLICK_DRAG_THRESHOLD:
			harvest_clicked.emit(_screen_to_world(event.position))
		elif was_single_touch:
			_start_glide()
		# A finger lifted: every remaining one re-baselines on its next move
		# instead of panning / zooming from a stale position.
		for index in _touches:
			_settle[index] = true

	_reset_pinch()


func _handle_touch_drag(event: InputEventScreenDrag) -> void:
	if _touch_over_ui.get(event.index, false):
		return
	if not _touches.has(event.index):
		# After a finger lifts, the browser may renumber the one still down:
		# adopt it as the tracked finger nearest its position (re-baseline,
		# no movement). Anything else is a touch we never saw start.
		if _touches.size() != 1:
			return
		_adopt_index(_nearest_touch(event.position), event.index)
		_settle[event.index] = true
	# Deltas come from our own last position of this finger, not
	# event.relative, which a renumbered touch can measure from another finger.
	var previous: Vector2 = _touches[event.index]
	_touches[event.index] = event.position
	if _settle.has(event.index):
		_settle.erase(event.index)
		if _touches.size() == 2:
			_reset_pinch()
		return

	if _touches.size() == 1:
		_pan_by(-(event.position - previous) / camera.zoom.x)
	elif _touches.size() == 2:
		# Zoom by the change in finger distance and pan so the world point
		# that was under the fingers' midpoint stays under it (like any map
		# app): moving both fingers pans, spreading them zooms around them.
		var new_distance := _current_pinch_distance()
		var new_midpoint := _current_pinch_midpoint()
		if _pinch_distance > 0.0:
			var anchor := _screen_to_world_at(_pinch_midpoint, camera.zoom.x)
			_set_zoom(camera.zoom.x * (new_distance / _pinch_distance))
			global_position += anchor - _screen_to_world_at(new_midpoint, camera.zoom.x)
		_pinch_distance = new_distance
		_pinch_midpoint = new_midpoint


## The tracked touch index whose last position is nearest `pos`.
func _nearest_touch(pos: Vector2) -> int:
	var best := -1
	var best_d := INF
	for index in _touches:
		var d: float = (_touches[index] as Vector2).distance_to(pos)
		if d < best_d:
			best_d = d
			best = index
	return best


## Moves a tracked touch's state from index `from` to `to` (a browser
## renumbered it).
func _adopt_index(from: int, to: int) -> void:
	if from == to or from < 0:
		return
	for dict in [_touches, _touch_press_positions, _touch_press_msec, _touch_over_ui, _settle]:
		if dict.has(from):
			dict[to] = dict[from]
			dict.erase(from)


## Long press: one finger, the only one of its gesture, held still for
## LONG_PRESS_SEC - fires info once, while still held (so the panel opens
## without lifting), and turns the release into a non-tap.
func _process(delta: float) -> void:
	_update_glide_and_zoom(delta)
	if _touches.size() != 1 or _multi_touch or _long_press_fired:
		return
	var index: int = _touches.keys()[0]
	var pos: Vector2 = _touches[index]
	if pos.distance_to(_touch_press_positions.get(index, pos)) >= CLICK_DRAG_THRESHOLD:
		return
	if Time.get_ticks_msec() - int(_touch_press_msec.get(index, Time.get_ticks_msec())) >= LONG_PRESS_SEC * 1000.0:
		_long_press_fired = true
		info_clicked.emit(_screen_to_world(pos))


## A one-pointer pan step (world px), remembered for the release's flick.
func _pan_by(world_delta: Vector2) -> void:
	global_position += world_delta
	_drag_samples.append([Time.get_ticks_msec(), world_delta])
	if _drag_samples.size() > 16:
		_drag_samples.pop_front()


## On release: glide at the drag's recent velocity (MOMENTUM_WINDOW_MSEC),
## if momentum is on and it was moving fast enough.
func _start_glide() -> void:
	var now := Time.get_ticks_msec()
	var moved := Vector2.ZERO
	var oldest := now
	for sample in _drag_samples:
		if now - int(sample[0]) <= MOMENTUM_WINDOW_MSEC:
			moved += sample[1]
			oldest = mini(oldest, int(sample[0]))
	_drag_samples.clear()
	var span := maxf(float(now - oldest), 16.0) / 1000.0
	var velocity := moved / span
	_glide = velocity if momentum and velocity.length() >= MOMENTUM_MIN_SPEED else Vector2.ZERO


func _stop_glide() -> void:
	_glide = Vector2.ZERO
	_drag_samples.clear()


## Wheel zoom: multiply the target (from the current target while easing).
func _ease_zoom(factor: float) -> void:
	var from := _zoom_target if _zoom_target > 0.0 else camera.zoom.x
	_zoom_target = clampf(from * factor, min_zoom, max_zoom)


func _update_glide_and_zoom(delta: float) -> void:
	if _glide != Vector2.ZERO:
		global_position += _glide * delta
		_glide *= exp(-MOMENTUM_DECAY * delta)
		if _glide.length() < MOMENTUM_MIN_SPEED:
			_glide = Vector2.ZERO
	if _zoom_target > 0.0:
		var z := lerpf(camera.zoom.x, _zoom_target, 1.0 - exp(-ZOOM_EASE * delta))
		if absf(z - _zoom_target) < 0.001:
			z = _zoom_target
			_zoom_target = -1.0
		_set_zoom(z)


func is_gliding() -> bool:
	return _glide != Vector2.ZERO


func _screen_to_world(screen_pos: Vector2) -> Vector2:
	return get_viewport().canvas_transform.affine_inverse() * screen_pos


func _current_pinch_distance() -> float:
	var positions := _touches.values()
	return (positions[0] - positions[1]).length()


## Re-baselines the pinch whenever the set of fingers changes, so the next
## drag measures from the current finger positions (0 = not pinching).
func _reset_pinch() -> void:
	if _touches.size() == 2:
		_pinch_distance = _current_pinch_distance()
		_pinch_midpoint = _current_pinch_midpoint()
	else:
		_pinch_distance = 0.0


func _current_pinch_midpoint() -> Vector2:
	var positions := _touches.values()
	return (positions[0] + positions[1]) * 0.5


## World position shown at a screen point for the camera at this node's
## current position and the given zoom - computed directly rather than
## through the viewport's canvas transform, which only catches up with a
## zoom or position change on the camera's next update. Camera2D is centred
## on this node (default anchor, no offset).
func _screen_to_world_at(screen_pos: Vector2, zoom: float) -> Vector2:
	return global_position + (screen_pos - get_viewport().get_visible_rect().size * 0.5) / zoom


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_dragging = false
		_touches.clear()
		_touch_press_positions.clear()
		_touch_over_ui.clear()
		_touch_press_msec.clear()
		_settle.clear()
		_long_press_fired = false
		_stop_glide()
		_pinch_distance = 0.0
		_multi_touch = false


func _set_zoom(value: float) -> void:
	var z := clampf(value, min_zoom, max_zoom)
	camera.zoom = Vector2(z, z)
