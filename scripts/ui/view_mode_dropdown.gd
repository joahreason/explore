extends OptionButton

## Lists the views ViewModes gives a label; selecting one calls set_view_mode() on
## the World node (grandparent: World/UI/ViewModeDropdown -> World). The first item
## is the default view (ChunkManager._view_mode: World = terrain + every
## placed resource, Phase 13.5), since the dropdown starts on it.

const ViewModesScript := preload("res://scripts/world/view_modes.gd")

## ViewModes.VIEWS' labelled views, in its order (review A2).
var _items := ViewModesScript.listed()


func _ready() -> void:
	for item in _items:
		add_item(item["label"])
	item_selected.connect(_on_item_selected)


func _on_item_selected(index: int) -> void:
	var world := get_node("../..")
	world.set_view_mode(_items[index]["mode"])
