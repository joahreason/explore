extends SceneTree

## In-game time: GameClock's clock and calendar, the daylight tint, and the
## scene wiring - DayNight tints the gameplay views by the clock (data views
## stay untinted, UI never), the clock label shows date and time, the clock
## runs with the game, and it is saved per seed with the player's changes.
## Run via tests/run_tests.sh.

const SEED := 4242
const DIR := "user://test_game_clock"

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

	# Clock and calendar.
	var c := GameClock.new()
	check(c.time_text() == "08:00" and c.date_text() == "Spring 1, Year 1", "a new world starts at Spring 1, Year 1, 08:00 (%s, %s)" % [c.date_text(), c.time_text()])
	c.advance(60.0 / GameClock.MINUTES_PER_SECOND)
	check(c.time_text() == "09:00", "a real minute is an in-game hour at 1 min/s (%s)" % c.time_text())
	c.minutes = GameClock.MINUTES_PER_DAY + 5
	check(c.date_text() == "Spring 2, Year 1" and c.time_text() == "00:05", "midnight rolls the day over (%s %s)" % [c.date_text(), c.time_text()])
	c.minutes = GameClock.MINUTES_PER_DAY * GameClock.DAYS_PER_SEASON
	check(c.date_text() == "Summer 1, Year 1", "30 days make a season (%s)" % c.date_text())
	c.minutes = GameClock.MINUTES_PER_DAY * (GameClock.DAYS_PER_SEASON * 4 - 1) + 23 * 60 + 59
	var last := c.date_text() + " " + c.time_text()
	c.advance(1.0 / GameClock.MINUTES_PER_SECOND)
	check(last == "Winter 30, Year 1 23:59" and c.date_text() == "Spring 1, Year 2" and c.time_text() == "00:00", "the year rolls over after Winter 30 (%s -> %s %s)" % [last, c.date_text(), c.time_text()])
	c.advance(-50.0)
	check(c.time_text() == "00:00", "time never runs backwards")

	# Daylight.
	var noon := GameClock.light_at(12.0)
	var night := GameClock.light_at(0.0)
	var dawn := GameClock.light_at(6.0)
	var dusk := GameClock.light_at(18.5)
	check(noon == Color(1, 1, 1), "midday is untinted")
	check(night.b > night.r and night.get_luminance() < 0.5, "night is dark and blue (%s)" % night)
	check(dawn.r > dawn.b and dusk.r > dusk.b and dawn.get_luminance() > night.get_luminance(), "dawn and dusk are warm (%s, %s)" % [dawn, dusk])
	var smooth := true
	var prev := GameClock.light_at(0.0)
	for m in range(1, 24 * 60 + 1):
		var col := GameClock.light_at(m / 60.0)
		smooth = smooth and absf(col.r - prev.r) < 0.02 and absf(col.g - prev.g) < 0.02 and absf(col.b - prev.b) < 0.02
		prev = col
	check(smooth and GameClock.light_at(24.0) == GameClock.light_at(0.0) and GameClock.light_at(-1.0) == GameClock.light_at(23.0),
		"the tint changes smoothly minute by minute, wraps at midnight and for any hour")

	# Saved form.
	var w := WorldChanges.new()
	var fresh := w.to_dict(SEED)
	w.time_minutes = 12345.5
	var back := WorldChanges.new()
	check(not fresh.has("time") and back.from_dict(JSON.parse_string(JSON.stringify(w.to_dict(SEED))), SEED) and back.time_minutes == 12345.5,
		"time is saved with the changes (and left out for a new world)")
	check(back.from_dict(fresh, SEED) and back.time_minutes == -1.0, "a save without time reads as a new world's")

	# The scene.
	var world := await _world(DIR)
	var CM = world.get_script()
	var tint: CanvasModulate = world.get_node("DayNight")
	var label: Label = world.get_node("UI/ClockLabel")
	check(absf(world.clock.minutes - GameClock.START_MINUTES) < 5.0, "a world without a save starts at the start time")
	var before: float = world.clock.minutes
	for k in 10:
		await process_frame
	check(world.clock.minutes > before, "the clock runs with the game (%.3f -> %.3f)" % [before, world.clock.minutes])
	world.clock.minutes = 2.0 * 60.0  # 02:00, night
	await process_frame
	check(tint.color == world.clock.light() and tint.color.get_luminance() < 0.5, "World view is tinted by the time (night: %s)" % tint.color)
	check(label.text == "%s · %s" % [world.clock.date_text(), world.clock.time_text()] and label.text.begins_with("Spring 1, Year 1 · 02:0"),
		"clock label shows date and time (%s)" % label.text)
	world.set_view_mode(CM.ViewMode.TEMPERATURE)
	await process_frame
	check(tint.color == Color(1, 1, 1), "data views stay untinted")
	world.set_view_mode(CM.ViewMode.MATERIAL)
	await process_frame
	check(tint.color == world.clock.light(), "Terrain Only is tinted")

	# Saved per seed.
	world.clock.minutes = 3 * GameClock.MINUTES_PER_DAY + 15 * 60
	world.regenerate("777")
	check(absf(world.clock.minutes - GameClock.START_MINUTES) < 1.0, "a different (new) seed starts at the start time")
	world.regenerate(str(SEED))
	check(absf(world.clock.minutes - (3 * GameClock.MINUTES_PER_DAY + 15 * 60)) < 1.0, "switching back restores that seed's time (%s)" % world.clock.date_text())
	world._save_gameplay_state()
	var saved: float = world.clock.minutes
	world.queue_free()
	await process_frame
	var world2 := await _world(DIR)
	check(absf(world2.clock.minutes - saved) < 1.0, "a reloaded world continues from its saved time (%s %s)" % [world2.clock.date_text(), world2.clock.time_text()])
	world2.queue_free()
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
	return world


func _clean() -> void:
	var d := DirAccess.open(DIR)
	if d == null:
		return
	for f in d.get_files():
		d.remove(f)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR))
