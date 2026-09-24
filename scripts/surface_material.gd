class_name SurfaceMaterial
extends "res://scripts/resource_definition.gd"

## Phase 13.5: one kind of ground surface (grass, dirt, sand, mud, snow, ...).
## WHERE it can occur is the inherited suitability data - curves, required
## curves, categorical weights, affinities - evaluated by the same
## ResourceManager.get_suitability() as every resource (plan Rules 2 and 6),
## never the biome label (Rule 3). base_density is its prevalence (a scale on
## that suitability) and cluster_scale / cluster_strength shape the patch
## noise that decides which suitable material wins where (TerrainSurface).
## The fields below describe how it LOOKS, varied continuously by the tile.

@export_group("Ground Colour")
@export var display_name: String = ""
@export var ground_color: Color = Color(0.5, 0.5, 0.5)
## WorldGen.Geology int -> Color, replacing ground_color on that rock type
## (dirt, gravel and rock take their parent rock's colour).
@export var geology_colors: Dictionary = {}
## Up to two tints toward tint_color: amount = smoothstep(range.x, range.y,
## the EnvironmentalState field) (x > y ramps the other way), scaled by the
## tint colour's alpha (its maximum strength). Empty field = no tint.
@export var tint_field: String = ""
@export var tint_range: Vector2 = Vector2(0.0, 1.0)
@export var tint_color: Color = Color(0, 0, 0, 0)
@export var tint2_field: String = ""
@export var tint2_range: Vector2 = Vector2(0.0, 1.0)
@export var tint2_color: Color = Color(0, 0, 0, 0)
## Per-tile brightness variation (+-, deterministic per seed and tile), so
## even uniform ground doesn't read as one flat colour.
@export var jitter: float = 0.04
