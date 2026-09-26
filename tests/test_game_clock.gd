extends "res://tests/harness.gd"

## In-game time: GameClock's clock and calendar, the daylight tint, and the
## scene wiring - DayNight tints the gameplay views by the clock (data views
## stay untinted, UI never), the clock label shows date and time, the clock
## runs with the game, and it is saved per seed with the player's changes.
## Run via tests/run_tests.sh.

const SEED := 4242
const DIR := "user://test_game_clock"


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

	# Speed controls.
	var sc := GameClock.new()
	var steps: Array[String] = []
	for press in ["ff", "ff", "ff", "ff", "rw", "rw", "play", "play", "play", "rw", "play"]:
		match press:
			"ff": sc.fast_forward()
			"rw": sc.rewind()
			"play": sc.play_pause()
		steps.append("%s=%s" % [press, sc.rate()])
	check(", ".join(steps) == "ff=4.0, ff=16.0, ff=64.0, ff=4.0, rw=-4.0, rw=-16.0, play=1.0, play=0.0, play=1.0, rw=-4.0, play=1.0",
		"speeds: >> steps x4 -> x16 -> x64 -> x4, << likewise backwards, play returns to x1, then toggles pause (%s)" % ", ".join(steps))
	sc.minutes = 600.0
	sc.fast_forward()
	sc.fast_forward()
	sc.fast_forward()
	sc.advance(1.0)
	var ff_ok := is_equal_approx(sc.minutes, 600.0 + 64.0 * GameClock.MINUTES_PER_SECOND)
	sc.play_pause()
	sc.play_pause()
	sc.advance(10.0)
	var pause_ok := is_equal_approx(sc.minutes, 600.0 + 64.0 * GameClock.MINUTES_PER_SECOND) and sc.speed_text() == "Paused"
	sc.rewind()
	sc.advance(1000.0)
	check(ff_ok and pause_ok and sc.minutes == 0.0 and sc.speed_text() == "<< x4",
		"x64 runs an in-game hour per real second, pause holds the time, rewind stops at the very start")

	# Sleeping in a tent: fast-forward to the next night start or dawn.
	var d0 := 3.0 * GameClock.MINUTES_PER_DAY
	var night_start := GameClock.NIGHT_START_HOUR * 60
	var dawn_start := GameClock.DAWN_START_HOUR * 60
	var clock_text := func(m: float) -> String: return "%02d:%02d" % [int(m / 60), int(fmod(m, 60))]
	check(GameClock.next_wake(d0 + 8 * 60) == d0 + night_start and GameClock.next_wake(d0 + 21 * 60) == d0 + GameClock.MINUTES_PER_DAY + dawn_start
		and GameClock.next_wake(d0 + dawn_start - 3 * 60) == d0 + dawn_start and GameClock.next_wake(d0 + night_start - 30) == d0 + GameClock.MINUTES_PER_DAY + dawn_start,
		"sleep wakes at the next night start (%s) or dawn (%s), whichever comes first at least an hour away" % [clock_text.call(night_start), clock_text.call(dawn_start)])
	var sl := GameClock.new()
	sl.minutes = d0 + 8 * 60
	sl.fast_forward()
	sl.sleep()
	var real := 0.0
	var peak := 0.0
	var jump := 0.0
	var last_rate := sl.rate()
	var end_rates: Array[float] = []
	while sl.sleeping and real < 60.0:
		sl.advance(1.0 / 60.0)
		real += 1.0 / 60.0
		var r := sl.rate()
		peak = maxf(peak, r)
		jump = maxf(jump, absf(r - last_rate))
		last_rate = r
		end_rates.append(r)
	check(not sl.sleeping and sl.minutes == d0 + night_start and sl.rate() == 1.0 and sl.speed_text() == "",
		"a sleep from 08:00 ends exactly at night start (%s), back at normal speed (%s)" % [clock_text.call(night_start), sl.time_text()])
	check(real > 1.5 and real < 6.0 and peak > 0.9 * GameClock.SLEEP_SPEED,
		"12 hours pass in %.1f real seconds at up to x%d" % [real, int(peak)])
	check(jump < 0.1 * GameClock.SLEEP_SPEED and end_rates[end_rates.size() - 10] < 0.05 * GameClock.SLEEP_SPEED,
		"time eases in and slows down to normal speed rather than jumping (largest change per frame x%.1f)" % jump)
	sl.sleep()
	var asleep_text := sl.speed_text()
	sl.fast_forward()
	check(asleep_text == "Sleeping" and not sl.sleeping and sl.rate() == GameClock.SPEEDS[0], "the time controls wake a sleeper")

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
	# The buttons drive the clock; the label shows the speed.
	var controls: Node = world.get_node("UI/TimeControls")
	controls.get_node("FastForward").pressed.emit()
	controls.get_node("FastForward").pressed.emit()
	await process_frame
	var ff_label := label.text
	var ff_pressed: bool = controls.get_node("FastForward").button_pressed
	controls.get_node("PlayPause").pressed.emit()
	await process_frame
	var play_text: String = controls.get_node("PlayPause").text
	controls.get_node("PlayPause").pressed.emit()
	await process_frame
	var paused_label := label.text
	var paused_text: String = controls.get_node("PlayPause").text
	var held: float = world.clock.minutes
	for f in 5:
		await process_frame
	var held_ok: bool = world.clock.minutes == held
	controls.get_node("Rewind").pressed.emit()
	await process_frame
	check(ff_label.ends_with(">> x16") and ff_pressed and play_text == "||" and paused_label.ends_with("Paused") and paused_text == ">"
		and held_ok and world.clock.rate() == -4.0 and controls.get_node("Rewind").button_pressed and not controls.get_node("FastForward").button_pressed,
		"buttons: >> twice = x16 (label '%s'), play -> normal ('||'), again -> paused ('%s', clock held), << -> x-4" % [ff_label, paused_label])
	world.clock.play_pause()
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
	finish()


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
