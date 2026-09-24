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
## or {} when the click hit bare ground; its "entity" (Phase 15
## ResourceInstance) adds the quality line (when it has one) and a size /
## health / state line. deposits: deposit name ->
## Vector2(potential (how much exists here), exposure (how much of it shows,
## ResourceManager.get_exposure())). farming: Phase 10 farming potential
## (0..1), or < 0 to leave the line out. shade: Phase 13 canopy shade
## (ResourceManager.get_shade()), < 0 = left out. ground: Phase 13.5 surface
## material name (TerrainSurface), "" on water.
func show_info(tile: Vector2i, sample: Dictionary, classified: Dictionary, resource: Dictionary = {}, deposits: Dictionary = {}, farming: float = -1.0, shade: float = -1.0, ground: String = "") -> void:
	visible = true

	var lines: Array[String] = []
	lines.append("[b]Tile (%d, %d)[/b]" % [tile.x, tile.y])
	lines.append("")
	if ground != "":
		lines.append("[b]Ground:[/b] %s" % ground)
	if resource.is_empty():
		lines.append("[b]Resource:[/b] -")
	else:
		lines.append("[b]Resource:[/b] %s (%s)" % [resource["name"], resource["guild_name"]])
		var entity = resource.get("entity")
		if entity != null:
			if entity.quality >= 0.0:
				lines.append("[b]Quality:[/b] %s (%.2f)" % [entity.tier, entity.quality])
			lines.append("[b]Size:[/b] %.2f  [b]Health:[/b] %.0f / %.0f  [b]State:[/b] %s" % [entity.size, entity.health, entity.max_health, entity.harvest_state])
	if not deposits.is_empty():
		var parts: Array[String] = []
		for ore_name in deposits:
			var d: Vector2 = deposits[ore_name]
			parts.append("%s %.2f (%s)" % [ore_name, d.x, "exposed" if d.y >= 0.5 else "hidden"])
		lines.append("[b]Deposits:[/b] %s" % ", ".join(parts))
	if farming >= 0.0:
		lines.append("[b]Farming potential:[/b] %.2f" % farming)
	if shade >= 0.0:
		lines.append("[b]Shade:[/b] %.2f" % shade)
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
