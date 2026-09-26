extends ScrollContainer

## ScrollContainer only scrolls via mouse wheel or dragging the scrollbar
## thumb itself - dragging anywhere in the content area (the natural touch
## gesture on mobile) does nothing by default. This adds that.
## Touch arrives here as emulated left-mouse press/motion (Project Settings
## default "emulate_mouse_from_touch"), so listening for InputEventMouse*
## covers touch-drag and an equivalent desktop click-drag-to-scroll for
## free. Requires the scrolled content's mouse_filter be set to Ignore (see
## world.tscn) so presses over it reach this node's _gui_input instead of
## being consumed by the content control itself.

var _dragging: bool = false


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		accept_event()
	elif event is InputEventMouseMotion and _dragging:
		scroll_vertical -= int(event.relative.y)
		accept_event()
