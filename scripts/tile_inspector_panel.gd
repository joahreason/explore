extends PanelContainer

## Shows every WorldGen sample field plus the classified base biome/subtype/
## modifiers for whatever tile was last clicked - see camera_rig.gd's
## "clicked" signal (emitted on a left click/tap that wasn't a drag) and
## chunk_manager.gd's _on_tile_clicked(), which drives this panel.

@onready var label: RichTextLabel = $Margin/VBox/Scroll/Label
@onready var close_button: Button = $Margin/VBox/CloseButton


func _ready() -> void:
	visible = false
	close_button.pressed.connect(func(): visible = false)


## resource: the placed instance under the click (ChunkManager._resource_at()),
## or {} when the click hit bare ground. deposits: ore name -> potential (how
## much exists here); sample["rock_exposure"] says whether it shows.
func show_info(tile: Vector2i, sample: Dictionary, classified: Dictionary, resource: Dictionary = {}, deposits: Dictionary = {}) -> void:
	visible = true

	var lines: Array[String] = []
	lines.append("[b]Tile (%d, %d)[/b]" % [tile.x, tile.y])
	lines.append("")
	if resource.is_empty():
		lines.append("[b]Resource:[/b] -")
	else:
		lines.append("[b]Resource:[/b] %s (%s)" % [resource["name"], resource["guild_name"]])
	if not deposits.is_empty():
		var parts: Array[String] = []
		for ore_name in deposits:
			parts.append("%s %.2f" % [ore_name, float(deposits[ore_name])])
		var shown := "exposed" if float(sample["rock_exposure"]) >= 0.5 else "hidden"
		lines.append("[b]Deposits:[/b] %s (%s)" % [", ".join(parts), shown])
	lines.append("[b]Biome:[/b] %s" % classified["base_biome"])

	var subtype: String = classified["subtype"]
	if subtype != "":
		lines.append("[b]Subtype:[/b] %s" % subtype)

	var modifiers: Array = classified["modifiers"]
	lines.append("[b]Modifiers:[/b] %s" % (", ".join(modifiers) if not modifiers.is_empty() else "-"))

	lines.append("[b]Confidence:[/b] %.2f" % float(classified["confidence"]))
	lines.append("")

	var keys := sample.keys()
	keys.sort()
	for key in keys:
		lines.append("%s: %s" % [key, _format_value(sample[key])])

	label.text = "\n".join(lines)


func _format_value(value) -> String:
	if value is float:
		return "%.4f" % value
	return str(value)
