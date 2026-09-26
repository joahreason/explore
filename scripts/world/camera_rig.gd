extends Node2D

## The camera: follows the player (player_path) loosely and turns clicks and
## taps into map actions.
## Following: the player can move freely inside a central zone (FOLLOW_ZONE
## of the view each way); once they step past its edge, the camera eases
## along to bring them back to the edge - it is never locked onto them.
## snap_to_player() centres it at once (new world, biome travel).
## Mouse: a left click (not a drag) is a map tap - ChunkManager walks the
## player there (and harvests a tapped resource); a right click shows
## tile/resource info; the scroll wheel zooms. Dragging doesn't pan.
## Touch: a tap is a map tap, a long press (LONG_PRESS_SEC, finger still)
## shows info, a two-finger pinch zooms.
## This node's position is the camera anchor that ChunkManager streams
## chunks around.

const SeedReloadScript := preload("res://scripts/ui/seed_reload.gd")

@export var zoom_factor: float = 1.15  # multiplicative per scroll notch
## Wheel zoom eases towards its target at this rate (per second).
const ZOOM_EASE := 14.0
@export var min_zoom: float = 0.2
@export var max_zoom: float = 6.0
## The player may move this far from the view centre (a fraction of the
## view's width / height, each way) before the camera follows.
const FOLLOW_ZONE := 0.2
## How fast the camera catches up once the player is past the zone (per
## second, exponential).
const FOLLOW_EASE := 6.0
@export var player_path: NodePath

## Direct children of this node are treated as "UI" for _is_over_ui() below -
## a press/tap starting on one of them (or on a currently-open popup, e.g.
## the view-mode dropdown's list) is never treated as a map tap / pinch. This
## is necessary because raw touch events (InputEventScreenTouch/Drag) are
## NOT consumed by Controls the way their emulated-mouse counterparts are - a
## tap on the dropdown or the inspector panel would otherwise ALSO reach
## this node's _unhandled_input as an unclaimed touch, corrupting pinch
## state and firing a spurious map tap under the UI. See world.tscn
## (ui_root_path wired to "../UI").
##
## project.godot has emulate_mouse_from_touch=true (needed so Controls like
## the dropdown/buttons/scrollbar respond to touch at all) - that means the
## first finger on the map ALSO arrives here as a synthetic mouse
## press/motion/release, and Godot dispatches that mirror BEFORE the touch
## event itself. _unhandled_input drops every emulated mouse event (device
## InputEvent.DEVICE_ID_EMULATION) so touches are handled once, by the touch
## path.
@export var ui_root_path: NodePath

## Below this much on-screen movement between press and release, a left
## click / touch is a tap; more is a drag, which does nothing.
const CLICK_DRAG_THRESHOLD := 6.0
## A single finger held this long without moving is a long press (info)
## instead of a tap - touch screens have no right click.
const LONG_PRESS_SEC := 0.5

## World-space position of a left click / tap that wasn't a drag (see
## CLICK_DRAG_THRESHOLD): chunk_manager.gd walks the player there.
signal map_tapped(world_pos: Vector2)
## World-space position of a right click / long press: chunk_manager.gd
## shows the tile inspector panel for it.
signal info_clicked(world_pos: Vector2)

@onready var camera: Camera2D = $Camera2D
@onready var _ui_root: Node = get_node(ui_root_path) if ui_root_path != NodePath() else null
@onready var _player: Node2D = get_node(player_path) if player_path != NodePath() else null

var _pressed: bool = false
## Wheel zoom target (eased towards in _process); <= 0 = none pending.
var _zoom_target: float = -1.0
var _press_position: Vector2 = Vector2.ZERO
var _touches: Dictionary = {}   # touch index -> last Vector2 position
var _touch_press_positions: Dictionary = {}  # touch index -> Vector2 at press
var _touch_over_ui: Dictionary = {}  # touch index -> bool, was its press over UI
var _touch_press_msec: Dictionary = {}  # touch index -> Time.get_ticks_msec() at press
## Touches whose next drag only re-baselines their position (no zoom): set
## for every remaining finger whenever the finger count changes.
var _settle: Dictionary = {}
## The current single-finger gesture already fired its long press, so its
## release is not also a tap.
var _long_press_fired: bool = false
var _pinch_distance: float = 0.0
## True once a second finger joined the current gesture, until every finger
## lifts: the last finger of a pinch lifting near where it started is not a
## tap.
var _multi_touch: bool = false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION:
		return  # a touch's mouse mirror - see the emulate_mouse_from_touch note above
	if event is InputEventMouseButton:
		_handle_mouse_button(event)
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
			_pressed = true
			_press_position = event.position
		elif _pressed:
			_pressed = false
			if event.position.distance_to(_press_position) < CLICK_DRAG_THRESHOLD:
				map_tapped.emit(get_global_mouse_position())
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
		# should never walk the player.
		var was_single_touch := _touches.size() == 1 and not _multi_touch
		var press_position: Vector2 = _touch_press_positions.get(event.index, event.position)
		_touches.erase(event.index)
		_touch_press_positions.erase(event.index)
		_touch_press_msec.erase(event.index)
		_settle.erase(event.index)
		if _touches.is_empty():
			_multi_touch = false
		if was_single_touch and not _long_press_fired and event.position.distance_to(press_position) < CLICK_DRAG_THRESHOLD:
			map_tapped.emit(_screen_to_world(event.position))
		# A finger lifted: every remaining one re-baselines on its next move.
		for index in _touches:
			_settle[index] = true

	_reset_pinch()


func _handle_touch_drag(event: InputEventScreenDrag) -> void:
	if _touch_over_ui.get(event.index, false):
		return
	if not _touches.has(event.index):
		# After a finger lifts, the browser may renumber the one still down:
		# adopt it as the tracked finger nearest its position (re-baseline).
		# Anything else is a touch we never saw start.
		if _touches.size() != 1:
			return
		_adopt_index(_nearest_touch(event.position), event.index)
		_settle[event.index] = true
	_touches[event.index] = event.position
	if _settle.has(event.index):
		_settle.erase(event.index)
		if _touches.size() == 2:
			_reset_pinch()
		return
	if _touches.size() == 2:
		# Zoom by the change in finger distance, around the view centre (the
		# camera stays with the player).
		var new_distance := _current_pinch_distance()
		if _pinch_distance > 0.0:
			_set_zoom(camera.zoom.x * (new_distance / _pinch_distance))
		_pinch_distance = new_distance


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


## Follow, zoom easing, and the long press: one finger, the only one of its
## gesture, held still for LONG_PRESS_SEC - fires info once, while still
## held (so the panel opens without lifting), and turns the release into a
## non-tap.
func _process(delta: float) -> void:
	_follow(delta)
	_update_zoom(delta)
	if _touches.size() != 1 or _multi_touch or _long_press_fired:
		return
	var index: int = _touches.keys()[0]
	var pos: Vector2 = _touches[index]
	if pos.distance_to(_touch_press_positions.get(index, pos)) >= CLICK_DRAG_THRESHOLD:
		return
	if Time.get_ticks_msec() - int(_touch_press_msec.get(index, Time.get_ticks_msec())) >= LONG_PRESS_SEC * 1000.0:
		_long_press_fired = true
		info_clicked.emit(_screen_to_world(pos))


## Eases the camera so the player is back inside the follow zone (no move
## while they are inside it).
func _follow(delta: float) -> void:
	var excess := follow_excess()
	if excess != Vector2.ZERO:
		global_position += excess * (1.0 - exp(-FOLLOW_EASE * delta))


## How far (world px) the player stands outside the follow zone - zero
## inside it or without a player.
func follow_excess() -> Vector2:
	if _player == null:
		return Vector2.ZERO
	var zone := get_viewport().get_visible_rect().size / camera.zoom * FOLLOW_ZONE
	var offset := _player.global_position - global_position
	return offset - offset.clamp(-zone, zone)


## Centres the camera on the player at once.
func snap_to_player() -> void:
	if _player != null:
		global_position = _player.global_position


## Wheel zoom: multiply the target (from the current target while easing).
func _ease_zoom(factor: float) -> void:
	var from := _zoom_target if _zoom_target > 0.0 else camera.zoom.x
	_zoom_target = clampf(from * factor, min_zoom, max_zoom)


func _update_zoom(delta: float) -> void:
	if _zoom_target > 0.0:
		var z := lerpf(camera.zoom.x, _zoom_target, 1.0 - exp(-ZOOM_EASE * delta))
		if absf(z - _zoom_target) < 0.001:
			z = _zoom_target
			_zoom_target = -1.0
		_set_zoom(z)


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
	else:
		_pinch_distance = 0.0


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_pressed = false
		_touches.clear()
		_touch_press_positions.clear()
		_touch_over_ui.clear()
		_touch_press_msec.clear()
		_settle.clear()
		_long_press_fired = false
		_pinch_distance = 0.0
		_multi_touch = false


func _set_zoom(value: float) -> void:
	var z := clampf(value, min_zoom, max_zoom)
	camera.zoom = Vector2(z, z)
