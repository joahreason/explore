extends SceneTree

## Phase 16 (world persistence): the player's changes to generated objects
## (harvested ones) are stored apart from the procedural state, keyed by the
## instance's stable key + the resource id they applied to, and saved per
## seed. Checks: the store itself (harvest, re-validation by resource id,
## apply to a record), its JSON form (round trip, wrong seed / version /
## malformed entries), files (round trip, missing file, "" = not saved),
## and in the real scene: a left-click harvest hides exactly that object and
## saves; info on it reports "harvested"; a reloaded world keeps it gone; a
## different seed doesn't see it; a stale change (key now holds another
## resource) never hides the new object; tests don't touch the player's
## save directory. Run via tests/run_tests.sh.

const SEED := 4242
const DIR := "user://test_world_changes"

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
	_clean()

	# The store.
	var c := WorldChanges.new()
	check(c.is_empty() and c.harvest("canopy_trees:3,4", "oak") and not c.harvest("canopy_trees:3,4", "oak") and c.size() == 1,
		"harvest records once (a second harvest of the same instance is a no-op)")
	check(c.is_harvested("canopy_trees:3,4", "oak") and not c.is_harvested("canopy_trees:3,4", "pine") and not c.is_harvested("canopy_trees:3,5", "oak"),
		"is_harvested needs both the key and the resource id")
	check(c.is_instance_harvested({"id": "oak", "guild": "canopy_trees", "cell": Vector2i(3, 4)})
		and not c.is_instance_harvested({"id": "oak", "cell": Vector2i(3, 4)}),
		"raw placement instances map to the same key (guild id, or own id without a guild)")
	var rec := _record("canopy_trees", Vector2i(3, 4), "oak")
	c.apply(rec)
	var other := _record("canopy_trees", Vector2i(3, 4), "pine")
	c.apply(other)
	check(rec.harvest_state == ResourceInstance.HARVESTED and rec.health == 0.0
		and other.harvest_state == ResourceInstance.HARVEST_AVAILABLE and other.health == other.max_health and c.size() == 1,
		"apply: harvested record -> 'harvested', health 0; a different resource at the key is left alone (stale change not applied)")

	# JSON form and files.
	var d := c.to_dict(SEED)
	var back := WorldChanges.new()
	check(back.from_dict(JSON.parse_string(JSON.stringify(d)), SEED) and back.is_harvested("canopy_trees:3,4", "oak") and back.size() == 1,
		"to_dict -> JSON -> from_dict round trip")
	check(not back.from_dict(d, SEED + 1) and back.is_empty(), "a file for another seed loads as empty")
	var old := d.duplicate(true)
	old["version"] = 0
	check(not back.from_dict(old, SEED) and back.is_empty(), "another format version loads as empty")
	var bad := d.duplicate(true)
	bad["changes"]["x:1,1"] = "junk"
	bad["changes"]["y:1,1"] = {"resource_id": "oak"}
	check(back.from_dict(bad, SEED) and back.size() == 1, "malformed entries are skipped")
	var path := DIR + "/unit.json"
	check(c.save(path, SEED) and back.load_file(path, SEED) and back.is_harvested("canopy_trees:3,4", "oak"), "save -> load_file round trip")
	check(not back.load_file(DIR + "/missing.json", SEED) and back.is_empty(), "missing file -> empty")
	check(not c.save("", SEED) and not back.load_file("", SEED), "path '' -> nothing written or read")

	# The real scene.
	var world := await _world(DIR)
	check(world.changes_path() == DIR + "/%d.json" % SEED, "a test-chosen dir is used (%s)" % world.changes_path())
	var target := _tree_in_view(world)
	check(not target.is_empty(), "found a tree in a loaded chunk")
	var chunk := Vector2i(((target["position"] as Vector2) / world.CHUNK_SIZE).floor())
	var before: int = world._loaded_placements[chunk]._positions.size()
	var click: Vector2 = ((target["position"] as Vector2).floor() + Vector2(0.5, 0.5)) * world.TILE_SIZE
	var harvested = world._on_harvest_clicked(click)
	var after: int = world._loaded_placements[chunk]._positions.size()
	check(harvested != null and harvested.harvest_state == ResourceInstance.HARVESTED and harvested.health == 0.0,
		"left-click harvest returns the record, now harvested with health 0 (%s)" % (harvested.key if harvested != null else "none"))
	var owner := Vector2i((harvested.world_position / world.CHUNK_SIZE).floor()) if harvested != null else chunk
	check(owner != chunk or after == before - 1, "its chunk draws exactly one marker fewer (%d -> %d)" % [before, after])
	check(FileAccess.file_exists(world.changes_path()) and world._changes.size() == 1, "the change is saved right away")
	world._on_tile_clicked(click)
	check(world._inspector_panel.label.text.contains("[b]State:[/b] harvested"), "right-click info on the spot reports it harvested")
	var again = world._on_harvest_clicked(click)
	check(again == null or again.key != harvested.key, "harvesting the same spot again never re-harvests it")
	var key: String = harvested.key
	var rid: String = harvested.resource_id
	world.queue_free()
	await process_frame

	# Reload: a new world for the same seed keeps it gone.
	var world2 := await _world(DIR)
	check(world2._changes.is_harvested(key, rid), "a reloaded world loads the change")
	var shown := false
	for marker_chunk in world2._chunk_placements:
		for entry in world2._chunk_placements[marker_chunk]:
			for inst in world2._unchanged(entry[1]):
				if ResourceInstance.key_for(inst.get("guild", inst["id"]), inst["cell"]) == key:
					shown = true
	check(not shown, "the harvested object is not drawn after reload")

	# Another seed doesn't see it; coming back does.
	world2.regenerate("777")
	check(world2._changes.is_empty(), "a different seed starts with no changes")
	world2.regenerate(str(SEED))
	check(world2._changes.is_harvested(key, rid), "switching back to the seed restores its changes")
	world2.queue_free()
	await process_frame

	# Stale change: the key now holds a different resource -> ignored.
	var stale := WorldChanges.new()
	stale.harvest(key, "not_" + rid)
	stale.save(DIR + "/%d.json" % SEED, SEED)
	var world3 := await _world(DIR)
	var e = world3.get_resource_instance(target)
	check(e.harvest_state == ResourceInstance.HARVEST_AVAILABLE and not world3._unchanged([target]).is_empty(),
		"a stale change (key now holds another resource) never hides or harvests the new object")
	world3.queue_free()
	await process_frame

	# Default dir under a test harness: nothing is read or written.
	var world4: Node2D = load("res://world.tscn").instantiate()
	world4.world_seed = SEED
	root.add_child(world4)
	await process_frame
	check(world4.changes_path() == "", "tests using the default dir never touch the player's saves")
	world4.queue_free()
	await process_frame

	_clean()
	print("RESULT %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)


func _world(dir: String) -> Node2D:
	var world: Node2D = load("res://world.tscn").instantiate()
	world.world_seed = SEED
	world.changes_dir = dir
	root.add_child(world)
	await process_frame
	world.flush_chunk_work()
	return world


## A mature tree (it has a sprite) in a chunk whose markers are loaded.
func _tree_in_view(world: Node2D) -> Dictionary:
	for chunk in world._chunk_placements:
		for entry in world._chunk_placements[chunk]:
			if entry[0][0] != world.CANOPY_TREES:
				continue
			for inst in entry[1]:
				if inst["id"] == "oak" or inst["id"] == "pine" or inst["id"] == "birch":
					return inst
	return {}


func _record(guild: String, cell: Vector2i, id: String) -> ResourceInstance:
	var r := ResourceInstance.new()
	r.key = ResourceInstance.key_for(guild, cell)
	r.resource_id = id
	return r


func _clean() -> void:
	var d := DirAccess.open(DIR)
	if d == null:
		return
	for f in d.get_files():
		d.remove(f)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR))
