extends Label

## Always-on readout of where the camera is: the world tile under the screen
## center (the coordinates the tile inspector and tests use), its chunk, and
## the zoom. Reads World/CameraRig every frame.

@onready var _world := get_node("../..")
@onready var _rig: Node2D = get_node("../../CameraRig")
@onready var _camera: Camera2D = get_node("../../CameraRig/Camera2D")


func _process(_delta: float) -> void:
	var tile_size: int = _world.TILE_SIZE
	var chunk_size: int = _world.CHUNK_SIZE
	var tile := Vector2i(floori(_rig.global_position.x / tile_size), floori(_rig.global_position.y / tile_size))
	var chunk := Vector2i(floori(float(tile.x) / chunk_size), floori(float(tile.y) / chunk_size))
	text = "Tile %d, %d   Chunk %d, %d   Zoom %.2f" % [tile.x, tile.y, chunk.x, chunk.y, _camera.zoom.x]
