extends OptionButton

## Phase 18 (developer tooling): picks the resource the Debug views
## (Suitability / Density / Patch Noise / Placement) show -
## ChunkManager.set_debug_resource(). Lists every placed resource as
## "Oak (Canopy Trees)". Only visible while a Debug view is showing; sits
## just below the "Go to biome" menu.

const SPACING := 8

@onready var _world := get_node("../..")
var _resources: Array[ResourceDefinition] = []


func _ready() -> void:
	var above := get_node_or_null("../BiomeTravelDropdown") as Control
	if above:
		var height := offset_bottom - offset_top
		offset_top = above.offset_bottom + SPACING
		offset_bottom = offset_top + height
	_resources = _world.debug_resources()
	var guild_names := {}
	for guild in _world.CONTENT.guilds:
		for member in guild.members:
			guild_names[member.id] = String(guild.id).capitalize()
	for definition in _resources:
		add_item("%s (%s)" % [String(definition.id).capitalize(), guild_names[definition.id]])
	select(_resources.find(_world.debug_resource()))
	item_selected.connect(func(index: int): _world.set_debug_resource(_resources[index]))
	visible = false


## Shown only in Debug views, and kept on the world's current resource
## (it can also be set from code, e.g. by tests).
func _process(_delta: float) -> void:
	visible = _world.is_debug_view()
	var current := _resources.find(_world.debug_resource())
	if current != selected:
		select(current)
