extends SceneTree

## Phase 15 (gameplay entities): every placed instance can be turned into a
## ResourceInstance record - stable key, resource id, position, quality and
## tier, size, health and harvest state - built on demand through
## ChunkManager.get_resource_instance(), the one lookup point. Checks: entity
## data, every field against its source (placement, get_quality(), the
## profile's size range, max_health x size, "available"), key uniqueness,
## determinism across rects, caches and evaluation order, and size following
## quality. Placement itself is untouched (tests/test_placement_snapshot.gd).
## Run via tests/run_tests.sh.

const SEED := 4242
const REGIONS := [Vector2i(0, 0), Vector2i(8000, -12000)]
const HALF := 48

var _fails := 0
var _passes := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		_passes += 1
		print("PASS ", msg)
	else:
		_fails += 1
		print("FAIL ", msg)


func _init() -> void:
	var world: Node2D = load("res://world.tscn").instantiate()
	world.world_seed = SEED
	root.add_child(world)
	await process_frame
	world.flush_chunk_work()

	# Data: every placeable definition has a usable size and health, every
	# profile a sane size range.
	var data_ok := true
	var profiles := {}
	for guild in world.GUILD_STACK:
		for member in guild.members:
			data_ok = data_ok and member.base_size > 0.0 and member.max_health > 0.0
			if member.quality_profile != null:
				profiles[member.quality_profile.id] = member.quality_profile
	for id in profiles:
		var r: Vector2 = profiles[id].size_by_quality
		data_ok = data_ok and r.x > 0.0 and r.x <= r.y
	check(data_ok and profiles.size() == 3, "every definition: base_size and max_health > 0; profiles %s: 0 < size range min <= max" % [profiles.keys()])

	# Every placed instance of every guild, as a record, against its sources.
	var fields_ok := true
	var unprofiled_ok := true
	var keys := {}
	var duplicates := 0
	var total := 0
	var records := {}  # key -> record, for the determinism check
	var by_tier := {}  # tree tier -> [size sum, count]
	for c in REGIONS:
		var rect := Rect2i(c - Vector2i(HALF, HALF), Vector2i(2 * HALF, 2 * HALF))
		var stack: Dictionary = world._place_stack(rect)
		for guild in world.GUILD_STACK:
			for inst in stack[guild]:
				var e = world.get_resource_instance(inst)
				var definition: ResourceDefinition = world._definitions_by_id()[inst["id"]]
				total += 1
				if e == null:
					fields_ok = false
					continue
				var q: float = world._instance_quality(inst)
				var profile = definition.quality_profile
				var expect_size := definition.base_size
				if profile != null:
					expect_size *= lerpf(profile.size_by_quality.x, profile.size_by_quality.y, q)
				fields_ok = fields_ok and e.key == ResourceInstance.key_for(guild.id, inst["cell"]) and e.guild_id == guild.id \
					and e.cell == inst["cell"] and e.resource_id == inst["id"] and e.world_position == inst["position"] \
					and e.quality == q and e.tier == (profile.tier_for(q) if profile != null else "") \
					and is_equal_approx(e.size, expect_size) and is_equal_approx(e.max_health, definition.max_health * e.size) \
					and e.health == e.max_health and e.harvest_state == ResourceInstance.HARVEST_AVAILABLE
				if profile == null:
					unprofiled_ok = unprofiled_ok and e.quality == -1.0 and e.tier == "" and e.size == definition.base_size
				if keys.has(e.key):
					duplicates += 1
				keys[e.key] = true
				records[e.key] = e
				if profile != null and profile.id == "tree_age":
					var t: Array = by_tier.get(e.tier, [0.0, 0])
					t[0] += e.size
					t[1] += 1
					by_tier[e.tier] = t
	check(total > 1000, "records built for every placed instance of all %d guilds (%d)" % [world.GUILD_STACK.size(), total])
	check(fields_ok, "every field matches its source: key, guild, cell, resource id, position, quality + tier, size, health = max_health = max_health x size, available")
	check(unprofiled_ok, "resources without a quality profile: quality -1, no tier, size = base_size")
	check(duplicates == 0, "keys unique across %d instances" % keys.size())
	var mean := func(tier: String) -> float:
		var t: Array = by_tier.get(tier, [0.0, 0])
		return t[0] / maxf(t[1], 1.0)
	check(mean.call("young") < mean.call("mature") and mean.call("mature") < mean.call("old growth"),
		"tree size follows age: young %.2f < mature %.2f < old growth %.2f" % [mean.call("young"), mean.call("mature"), mean.call("old growth")])

	# Same records after dropping every cache and placing a different rect,
	# visited in reverse.
	world.clear_generation_caches()
	var rect0 := Rect2i(REGIONS[0] - Vector2i(HALF + 16, HALF + 16), Vector2i(2 * HALF + 32, 2 * HALF + 32))
	var stack0: Dictionary = world._place_stack(rect0)
	var same := true
	var compared := 0
	var guilds: Array = world.GUILD_STACK.duplicate()
	guilds.reverse()
	for guild in guilds:
		var list: Array = stack0[guild].duplicate()
		list.reverse()
		for inst in list:
			var e = world.get_resource_instance(inst)
			if not records.has(e.key):
				continue
			var r = records[e.key]
			compared += 1
			same = same and e.resource_id == r.resource_id and e.world_position == r.world_position and e.quality == r.quality \
				and e.tier == r.tier and e.size == r.size and e.health == r.health and e.harvest_state == r.harvest_state
	check(same and compared > 500, "records identical from another rect, cold caches and reverse order (%d)" % compared)

	var unknown = world.get_resource_instance({"id": "no_such_resource", "cell": Vector2i.ZERO, "position": Vector2.ZERO})
	check(unknown == null, "unknown resource id -> no record")

	print("RESULT %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)
