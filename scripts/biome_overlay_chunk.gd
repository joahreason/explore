extends Node2D

## One chunk's worth of biome overlay: semi-transparent fill per biome,
## outlines only where the biome actually changes, and a label near the
## chunk center. Built from a (chunk_size+1)^2 grid so edge outlines line
## up correctly with the neighboring chunk without needing it to be loaded.

const BiomeClassifierScript := preload("res://scripts/biome_classifier.gd")

var _cells: Array = []    # base biome names - drives fill color + outlines
var _labels: Array = []   # display text per cell - may differ from _cells
var _chunk_size: int = 16
var _tile_size: int = 12


## labels defaults to cells (base-biome-only label) when not given, so
## existing callers (Base Biome view) don't need to change.
func setup(cells: Array, chunk_size: int, tile_size: int, labels: Array = []) -> void:
	_cells = cells
	_labels = labels if not labels.is_empty() else cells
	_chunk_size = chunk_size
	_tile_size = tile_size
	queue_redraw()


func _draw() -> void:
	var stride := _chunk_size + 1

	for ly in range(_chunk_size):
		for lx in range(_chunk_size):
			var biome: String = _cells[ly * stride + lx]
			var color: Color = BiomeClassifierScript.BIOME_COLORS.get(biome, Color(1, 1, 1, 0.25))
			draw_rect(Rect2(lx * _tile_size, ly * _tile_size, _tile_size, _tile_size), color, true)

	var outline_color := Color(0, 0, 0, 0.65)
	for ly in range(_chunk_size):
		for lx in range(_chunk_size):
			var biome: String = _cells[ly * stride + lx]
			var right: String = _cells[ly * stride + (lx + 1)]
			if right != biome:
				var x := float((lx + 1) * _tile_size)
				draw_line(Vector2(x, ly * _tile_size), Vector2(x, (ly + 1) * _tile_size), outline_color, 1.0)
			var below: String = _cells[(ly + 1) * stride + lx]
			if below != biome:
				var y := float((ly + 1) * _tile_size)
				draw_line(Vector2(lx * _tile_size, y), Vector2((lx + 1) * _tile_size, y), outline_color, 1.0)

	var center_label: String = _labels[(_chunk_size / 2) * stride + (_chunk_size / 2)]
	var font := ThemeDB.fallback_font
	var text_pos := Vector2(4, _chunk_size * _tile_size * 0.5)
	draw_string(font, text_pos + Vector2(1, 1), center_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.BLACK)
	draw_string(font, text_pos, center_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
