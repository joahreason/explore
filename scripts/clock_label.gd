extends Label

## On-screen clock and date of the world's in-game time
## (ChunkManager.clock): "Spring 3, Year 1 · 14:05".

@onready var _world := get_node("../..")


func _process(_delta: float) -> void:
	text = "%s · %s" % [_world.clock.date_text(), _world.clock.time_text()]
