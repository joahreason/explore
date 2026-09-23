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
## or {} when the click hit bare ground. deposits: deposit name ->
## Vector2(potential (how much exists here), exposure (how much of it shows,
## ResourceManager.get_exposure())). farming: Phase 10 farming potential
## (0..1), or < 0 to leave the line out.
func show_info(tile: Vector2i, sample: Dictionary, classified: Dictionary, resource: Dictionary = {}, deposits: Dictionary = {}, farming: float = -1.0) -> void:
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
			var d: Vector2 = deposits[ore_name]
			parts.append("%s %.2f (%s)" % [ore_name, d.x, "exposed" if d.y >= 0.5 else "hidden"])
		lines.append("[b]Deposits:[/b] %s" % ", ".join(parts))
	if farming >= 0.0:
		lines.append("[b]Farming potential:[/b] %.2f" % farming)
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
