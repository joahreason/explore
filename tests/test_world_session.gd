extends "res://tests/harness.gd"

## WorldSession (scripts/world/world_session.gd, §4.1 step 3) without the
## world scene: a new seed starts at START_MINUTES with no position; a
## harvest is recorded by key, saved with the time and position, and loaded
## back for that seed only; the clock asks to be saved once per in-game
## hour and not more often than CLOCK_SAVE_MSEC when fast-forwarding; a
## woken sleeper is noticed. Run via tests/run_tests.sh.

const Session := preload("res://scripts/world/world_session.gd")
const GameClockScript := preload("res://scripts/world/game_clock.gd")
const DIR := "user://test_world_session"
const SEED := 77


func _clean() -> void:
	for f in ["%d.json" % SEED, "%d.json.bak" % SEED, "%d.json.tmp" % SEED, "%d.json" % (SEED + 1)]:
		if FileAccess.file_exists(DIR.path_join(f)):
			DirAccess.remove_absolute(DIR.path_join(f))


func _init() -> void:
	_clean()
	var path := DIR.path_join("%d.json" % SEED)
	var session = Session.new()
	var fresh: Variant = session.load_seed(path, SEED)
	check(fresh == null and session.clock.minutes == GameClockScript.START_MINUTES and session.changes.is_empty(),
		"a new seed: no saved position, the clock at its start, no changes")

	var inst := {"id": "oak", "guild": "canopy_trees", "cell": Vector2i(3, -4)}
	var entity := ResourceInstance.new()
	entity.key = ResourceInstance.key_for("canopy_trees", Vector2i(3, -4))
	entity.resource_id = "oak"
	var other := {"id": "pine", "guild": "canopy_trees", "cell": Vector2i(5, 5)}
	session.harvest(entity)
	check(session.is_harvested(inst) and not session.is_harvested(other) and entity.harvest_state == ResourceInstance.HARVESTED
		and session.unchanged([inst, other]) == [other],
		"a harvest is recorded by key and applied to the instance; unchanged() drops it")

	session.clock.minutes = 900.0
	session.save(Vector2(40, -8))
	var again = Session.new()
	var position: Variant = again.load_seed(path, SEED)
	check(position == Vector2(40, -8) and again.clock.minutes == 900.0 and again.is_harvested(inst),
		"saved and loaded back: position, time and the harvest")
	var elsewhere = Session.new()
	check(elsewhere.load_seed(DIR.path_join("%d.json" % (SEED + 1)), SEED + 1) == null and elsewhere.changes.is_empty(),
		"another seed has its own (empty) save")

	# Saves: once when an in-game hour passes, then not again within
	# CLOCK_SAVE_MSEC however fast time runs.
	var clock_saves = Session.new()
	clock_saves.clock.minutes = 60.0 * 60.0 - 0.01
	var first: bool = clock_saves.advance(1.0)
	clock_saves.clock.minutes = 61.0 * 60.0 - 0.01
	var soon: bool = clock_saves.advance(1.0)
	var within_hour: bool = clock_saves.advance(0.001)
	check(first and not soon and not within_hour, "the clock is saved when an hour passes, at most every %d ms" % Session.CLOCK_SAVE_MSEC)

	var sleeper = Session.new()
	sleeper.tent_tile = Vector2i(1, 1)
	sleeper.clock.sleep()
	var asleep: bool = sleeper.woke_in_tent()
	sleeper.clock.wake()
	check(not asleep and sleeper.woke_in_tent(), "a sleeper in a tent is noticed once the clock wakes them")

	_clean()
	finish()
