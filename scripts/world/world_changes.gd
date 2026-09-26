class_name WorldChanges
extends RefCounted

## Phase 16 of docs/resource-generation-plan.md: the gameplay state - what
## the player changed - kept apart from the procedural state, which the
## generator still decides deterministically ("there should be an oak
## here"). Only the changes are stored ("the player harvested it"), never
## the world.
##
## Keyed by ResourceInstance.key ("<guild id>:<cell>", the stable placement
## key) and recording the resource_id it applied to (plan Phase 16
## amendment): generation can change between content versions (a retuned
## curve, a new species), so a change only applies while the generated
## instance at its key is still that resource. A mismatch is never applied
## to the different object: every read re-validates the resource id
## (is_harvested(), apply()), so a stale change simply stops applying.
##
## Saved per world seed as a small JSON file (save() / load_file()); the
## caller decides when (ChunkManager saves after every change).

const FORMAT_VERSION := 1

## key -> {"resource_id": String, "harvest_state": String}
var _changes: Dictionary = {}
## The world's in-game time (GameClock.minutes) when last saved, -1 = none
## (a new world). Saved in the same per-seed file as the changes.
var time_minutes: float = -1.0
## Where the player stood (world px) when last saved; has_player_position
## false = none (a new world: ChunkManager spawns them near the origin).
var player_position := Vector2.ZERO
var has_player_position := false


func is_empty() -> bool:
	return _changes.is_empty()


func size() -> int:
	return _changes.size()


## Marks the instance at `key`, generated as `resource_id`, harvested.
## Returns false if it already was.
func harvest(key: String, resource_id: String) -> bool:
	if is_harvested(key, resource_id):
		return false
	_changes[key] = {"resource_id": resource_id, "harvest_state": ResourceInstance.HARVESTED}
	return true


## True if the instance at `key`, generated as `resource_id`, was harvested.
func is_harvested(key: String, resource_id: String) -> bool:
	var change: Dictionary = _changes.get(key, {})
	return change.get("resource_id", "") == resource_id and change.get("harvest_state", "") == ResourceInstance.HARVESTED


## The same test for a raw placement instance ({id, cell, guild?}).
func is_instance_harvested(inst: Dictionary) -> bool:
	if _changes.is_empty():
		return false
	var key := ResourceInstance.key_for(inst.get("guild", inst["id"]), inst["cell"])
	return is_harvested(key, inst["id"])


## Applies this state to a freshly built ResourceInstance: a harvested one
## gets harvest_state "harvested" and health 0. A change whose key now holds
## a different resource is not applied. Read-only, so generation threads can
## call it while holding the generation lock.
func apply(record) -> void:
	var change: Dictionary = _changes.get(record.key, {})
	if change.is_empty() or change.get("resource_id", "") != record.resource_id:
		return
	record.harvest_state = change.get("harvest_state", record.harvest_state)
	if record.harvest_state == ResourceInstance.HARVESTED:
		record.health = 0.0


func clear() -> void:
	_changes.clear()
	time_minutes = -1.0
	player_position = Vector2.ZERO
	has_player_position = false


func to_dict(world_seed: int) -> Dictionary:
	var data := {"version": FORMAT_VERSION, "seed": world_seed, "changes": _changes.duplicate(true)}
	if time_minutes >= 0.0:
		data["time"] = time_minutes
	if has_player_position:
		data["player"] = [player_position.x, player_position.y]
	return data


## Loads a to_dict() result; returns false (and stays empty) if it is for
## another seed or format version, or malformed.
func from_dict(data: Dictionary, world_seed: int) -> bool:
	clear()
	if int(data.get("version", -1)) != FORMAT_VERSION or int(data.get("seed", 0)) != world_seed:
		return false
	var changes = data.get("changes", {})
	if not changes is Dictionary:
		return false
	var time = data.get("time", -1.0)
	if time is float or time is int:
		time_minutes = maxf(float(time), -1.0)
	var player = data.get("player", null)
	if player is Array and player.size() == 2 and (player[0] is float or player[0] is int) and (player[1] is float or player[1] is int):
		player_position = Vector2(float(player[0]), float(player[1]))
		has_player_position = true
	for key in changes:
		var change = changes[key]
		if change is Dictionary and change.has("resource_id") and change.has("harvest_state"):
			_changes[String(key)] = {"resource_id": String(change["resource_id"]), "harvest_state": String(change["harvest_state"])}
	return true


## Writes to_dict() as JSON; "" = not persisted (nothing written). Never
## in place (review C4): the JSON goes to "<path>.tmp", the previous file
## becomes "<path>.bak", then the new one takes its name, so an interrupted
## write leaves the last good save readable.
func save(path: String, world_seed: int) -> bool:
	if path == "":
		return false
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var tmp := path + ".tmp"
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(to_dict(world_seed)))
	file.close()
	if file.get_error() != OK:
		return false
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path + ".bak")
		DirAccess.rename_absolute(path, path + ".bak")
	return DirAccess.rename_absolute(tmp, path) == OK


## Replaces this state with the file's (empty if path is "", there is no
## file, or it is unreadable or for another seed). A file that isn't valid
## JSON (a torn write), or is missing while "<path>.bak" exists, is read
## from the previous save instead.
func load_file(path: String, world_seed: int) -> bool:
	clear()
	if path == "":
		return false
	for candidate in [path, path + ".bak"]:
		if not FileAccess.file_exists(candidate):
			continue
		var json := JSON.new()  # parse() reports a torn file quietly; parse_string() logs an error
		if json.parse(FileAccess.get_file_as_string(candidate)) == OK and json.data is Dictionary:
			return from_dict(json.data, world_seed)
	return false
