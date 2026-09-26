extends RefCounted

## The player's session on one seed: the in-game clock, the saved changes
## (harvests, time, position), when the clock is next saved, and the tent the
## player sleeps in. No scene tree: ChunkManager moves the player and draws
## the tent. Main thread; generation reads `changes` under the generation
## mutex (GenerationContext.mutex), so harvest() is called with it held.

const WorldChangesScript := preload("res://scripts/world/world_changes.gd")
const GameClockScript := preload("res://scripts/world/game_clock.gd")
## Fast-forwarding saves the clock at most this often (real time).
const CLOCK_SAVE_MSEC := 10000

## In-game time (GameClock), advanced every frame and saved with `changes`;
## DayNight tints the world by it and the clock label shows it.
var clock = GameClockScript.new()
## Phase 16: the player's changes to generated objects (harvested ones)
## for the current seed.
var changes = WorldChangesScript.new()
## Sleeping in a camp tent: the tent's tile while the player is inside,
## null otherwise.
var tent_tile: Variant = null
var _path := ""  # save file, "" = not saved (see ChunkManager.changes_path())
var _seed := 0
var _last_clock_save_msec := -CLOCK_SAVE_MSEC


## Loads `world_seed`'s saved changes and time from `path` (a new world:
## none, START_MINUTES). Returns the saved player position, or null.
func load_seed(path: String, world_seed: int) -> Variant:
	_path = path
	_seed = world_seed
	clock.wake()
	changes.load_file(path, world_seed)
	clock.minutes = changes.time_minutes if changes.time_minutes >= 0.0 else GameClockScript.START_MINUTES
	return changes.player_position if changes.has_player_position else null


## Saves the changes, the current time and (unless null) where the player
## stands.
func save(player_position: Variant) -> void:
	changes.time_minutes = clock.minutes
	if player_position != null:
		changes.player_position = player_position
		changes.has_player_position = true
	changes.save(_path, _seed)


## Advances the clock by a frame. True when the clock should be saved: an
## in-game hour passed (about once a real minute at normal speed), at most
## every CLOCK_SAVE_MSEC when fast-forwarding.
func advance(delta: float) -> bool:
	var hour_before := floori(clock.minutes / 60.0)
	clock.advance(delta)
	if floori(clock.minutes / 60.0) == hour_before or Time.get_ticks_msec() - _last_clock_save_msec < CLOCK_SAVE_MSEC:
		return false
	_last_clock_save_msec = Time.get_ticks_msec()
	return true


## Records a harvested ResourceInstance (by its key); the caller saves.
func harvest(entity) -> void:
	changes.harvest(entity.key, entity.resource_id)
	changes.apply(entity)


func is_harvested(inst: Dictionary) -> bool:
	return changes.is_instance_harvested(inst)


## The instances of a placement list the player hasn't harvested.
func unchanged(instances: Array) -> Array:
	if changes.is_empty():
		return instances
	return instances.filter(func(inst): return not changes.is_instance_harvested(inst))


## Whether the player is asleep in a tent that the clock has woken them
## from (ChunkManager then brings them out).
func woke_in_tent() -> bool:
	return tent_tile != null and not clock.sleeping
