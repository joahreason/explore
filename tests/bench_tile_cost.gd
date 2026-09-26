extends SceneTree

## Per-tile generation cost, by step (review P1): sample(), the
## EnvironmentalState copy, classification, every species' suitability, every
## guild's density, and the terrain material and colour. Prints microseconds
## per tile for each step and a hash of every value computed, so a speed-up
## can be checked to change nothing.
##
##   timeout 600 $GODOT --headless --path . --script res://tests/bench_tile_cost.gd

const CONTENT: WorldContent = preload("res://resources/world_content.tres")
const SEED := 4242
const AREAS := [Vector2i(0, 0), Vector2i(-1052, -1212), Vector2i(3000, -2000)]
const SIZE := 48
const ROUNDS := 5


func _init() -> void:
	var species: Array[ResourceDefinition] = []
	for guild in CONTENT.guilds:
		for member in guild.members:
			if not species.has(member):
				species.append(member)
	var best := {}
	var values := PackedFloat64Array()
	for round in ROUNDS:
		# Best of ROUNDS: the first round also builds the noise objects.
		var gen := WorldGen.new()
		gen.configure(SEED)
		var usec := {"sample": 0, "state": 0, "classify": 0, "suitability": 0, "guilds": 0, "terrain": 0}
		values.clear()
		var tiles := 0
		for area in AREAS:
			for y in SIZE:
				for x in SIZE:
					var wx: int = area.x + x
					var wy: int = area.y + y
					var t := Time.get_ticks_usec()
					var s := gen.sample(wx, wy)
					var t1 := Time.get_ticks_usec()
					var state: EnvironmentalState = EnvironmentalState.from_sample(s)
					var t2 := Time.get_ticks_usec()
					var classified := BiomeClassifier.classify_full(s)
					var t3 := Time.get_ticks_usec()
					for def in species:
						values.append(ResourceManager.get_suitability(state, def, classified))
					var t4 := Time.get_ticks_usec()
					for guild in CONTENT.guilds:
						values.append(ResourceManager.get_guild_density(state, guild, SEED, wx, wy, classified))
					var t5 := Time.get_ticks_usec()
					if TerrainSurface.water_color(s, gen.sea_level) == null:
						ResourceManager.get_shade(state, SEED, wx, wy, classified)
						var material := TerrainSurface.material_at(state, SEED, wx, wy)
						var color := TerrainSurface.color_for(material, state, SEED, wx, wy)
						values.append(color.r)
						values.append(color.g)
						values.append(color.b)
					var t6 := Time.get_ticks_usec()
					usec["sample"] += t1 - t
					usec["state"] += t2 - t1
					usec["classify"] += t3 - t2
					usec["suitability"] += t4 - t3
					usec["guilds"] += t5 - t4
					usec["terrain"] += t6 - t5
					tiles += 1
		for step in usec:
			var per_tile: float = usec[step] / float(tiles)
			best[step] = minf(best.get(step, INF), per_tile)
	var line := "us/tile (best of %d):" % ROUNDS
	var total := 0.0
	for step in best:
		line += " %s %.1f" % [step, best[step]]
		total += best[step]
	print(line, " | total %.1f" % total)
	print("species %d, guilds %d, values %d, hash %d" % [species.size(), CONTENT.guilds.size(), values.size(), hash(values.to_byte_array())])
	quit(0)
