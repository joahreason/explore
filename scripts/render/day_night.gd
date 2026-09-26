extends CanvasModulate

## Day/night tint: multiplies the whole world (chunks, resource sprites,
## overlays - not the UI, which sits on its own CanvasLayer) by the daylight
## colour of the world's in-game time (ChunkManager.clock, GameClock.light()).
## Only the gameplay views (World, Terrain Only) are tinted; the data and
## debug views stay untinted so their colours read true.

@onready var _world := get_parent()


func _process(_delta: float) -> void:
	color = _world.clock.light() if _world.is_time_tinted_view() else Color(1, 1, 1)
