class_name GameClock
extends RefCounted

## In-game time: a clock and calendar that run while the game does, and the
## daylight colour the world is tinted with (DayNight, day_night.gd). Pure
## logic - ChunkManager owns one per world, advances it every frame and saves
## it per seed with the player's changes (WorldChanges.time_minutes).
##
## Time is total in-game minutes since Year 1, Spring 1, 00:00. Calendar:
## four seasons of DAYS_PER_SEASON days; no weekdays or months.

const MINUTES_PER_DAY := 1440
const DAYS_PER_SEASON := 30
const SEASONS: Array[String] = ["Spring", "Summer", "Autumn", "Winter"]
## In-game minutes per real second: a day lasts 24 real minutes.
const MINUTES_PER_SECOND := 1.0
## A new world starts in the morning of its first day.
const START_MINUTES := 8.0 * 60.0

## Daylight tint by hour (0..24), linear between: blue night, warm dawn and
## dusk, untinted day. The ends match so midnight is seamless.
const LIGHT_KEYS: Array[float] = [0.0, 4.5, 6.0, 7.5, 17.0, 18.5, 20.0, 24.0]
const LIGHT_COLORS: Array[Color] = [
	Color(0.34, 0.38, 0.62),
	Color(0.34, 0.38, 0.62),
	Color(0.95, 0.70, 0.58),
	Color(1, 1, 1),
	Color(1, 1, 1),
	Color(1.0, 0.68, 0.50),
	Color(0.34, 0.38, 0.62),
	Color(0.34, 0.38, 0.62),
]

## Time controls (TimeControls, time_controls.gd): fast-forward and rewind
## each step through SPEEDS; play/pause pauses at normal speed, or returns
## to normal speed from fast-forward / rewind.
const SPEEDS: Array[float] = [4.0, 16.0, 64.0]

## Sleeping in a camp tent (ChunkManager.enter_tent()) passes time until
## the next night start or dawn (the light's night and dawn keys above),
## whichever comes first at least SLEEP_MIN_MINUTES away. Time speeds up to
## SLEEP_SPEED over SLEEP_EASE_IN real seconds, then slows back to normal
## speed over the last SLEEP_EASE_OUT_MINUTES, stopping the sleep exactly
## at wake_minutes.
const NIGHT_START_HOUR := 20.0
const DAWN_START_HOUR := 4.5
const SLEEP_MIN_MINUTES := 60.0
const SLEEP_SPEED := 300.0
const SLEEP_EASE_IN := 0.4
const SLEEP_EASE_OUT_MINUTES := 60.0

var minutes: float = START_MINUTES
var paused: bool = false
## 0 normal speed, 1 fast-forward, -1 rewind; speed_level indexes SPEEDS.
var direction: int = 0
var speed_level: int = 0
var sleeping: bool = false
var wake_minutes: float = 0.0
var _sleep_seconds := 0.0


## Runs the clock for `real_seconds` of real time at the current rate
## (rate()); rewinding stops at the very start (minute 0), sleeping at
## wake_minutes (which ends the sleep).
func advance(real_seconds: float) -> void:
	var dt := maxf(real_seconds, 0.0)
	if sleeping:
		minutes = minf(minutes + dt * MINUTES_PER_SECOND * rate(), wake_minutes)
		_sleep_seconds += dt
		if minutes >= wake_minutes:
			sleeping = false
		return
	minutes = maxf(minutes + dt * MINUTES_PER_SECOND * rate(), 0.0)


## Multiplier on real time: 0 paused, 1 normal, +-SPEEDS[speed_level];
## asleep, eased between 1 and SLEEP_SPEED (see SLEEP_SPEED).
func rate() -> float:
	if sleeping:
		var ease_in := minf(_sleep_seconds / SLEEP_EASE_IN, 1.0)
		var ease_out := minf((wake_minutes - minutes) / SLEEP_EASE_OUT_MINUTES, 1.0)
		return maxf(1.0, SLEEP_SPEED * ease_in * ease_out)
	if paused:
		return 0.0
	if direction == 0:
		return 1.0
	return direction * SPEEDS[speed_level]


## Starts sleeping at normal speed (time controls reset) until
## next_wake().
func sleep() -> void:
	wake_minutes = next_wake(minutes)
	sleeping = true
	_sleep_seconds = 0.0
	direction = 0
	paused = false


## Ends a sleep early (time carries on at normal speed).
func wake() -> void:
	sleeping = false


## The first night start or dawn at least SLEEP_MIN_MINUTES after `from`.
static func next_wake(from: float) -> float:
	var day_start := floorf(from / MINUTES_PER_DAY) * MINUTES_PER_DAY
	var best := INF
	for day in 3:
		for hour in [DAWN_START_HOUR, NIGHT_START_HOUR]:
			var t: float = day_start + day * MINUTES_PER_DAY + hour * 60.0
			if t >= from + SLEEP_MIN_MINUTES and t < best:
				best = t
	return best


## The time controls wake a sleeper first.
func fast_forward() -> void:
	wake()
	_step_speed(1)


func rewind() -> void:
	wake()
	_step_speed(-1)


## Pauses or resumes at normal speed; from fast-forward / rewind it goes
## back to normal speed (playing). Wakes a sleeper, still playing.
func play_pause() -> void:
	if sleeping:
		wake()
		return
	if direction != 0:
		direction = 0
		paused = false
	else:
		paused = not paused


## "Sleeping", "Paused", ">> x16", "<< x4", or "" at normal speed.
func speed_text() -> String:
	if sleeping:
		return "Sleeping"
	if paused:
		return "Paused"
	if direction == 0:
		return ""
	return "%s x%d" % [">>" if direction > 0 else "<<", int(SPEEDS[speed_level])]


## Pressing the same direction again steps to the next speed (wrapping);
## switching direction starts at the first speed.
func _step_speed(dir: int) -> void:
	if direction == dir:
		speed_level = (speed_level + 1) % SPEEDS.size()
	else:
		direction = dir
		speed_level = 0
	paused = false


## Hour of the day as a fraction, 0 <= h < 24.
func hour_of_day() -> float:
	return fposmod(minutes, MINUTES_PER_DAY) / 60.0


func day_index() -> int:
	return floori(minutes / MINUTES_PER_DAY)


## Day of the season, 1-based.
func day_of_season() -> int:
	return posmod(day_index(), DAYS_PER_SEASON) + 1


func season() -> String:
	return SEASONS[posmod(floori(float(day_index()) / DAYS_PER_SEASON), SEASONS.size())]


## Year, 1-based.
func year() -> int:
	return floori(float(day_index()) / (DAYS_PER_SEASON * SEASONS.size())) + 1


## "HH:MM", 24-hour.
func time_text() -> String:
	var m := floori(fposmod(minutes, MINUTES_PER_DAY))
	return "%02d:%02d" % [m / 60, m % 60]


## "Spring 3, Year 1".
func date_text() -> String:
	return "%s %d, Year %d" % [season(), day_of_season(), year()]


func light() -> Color:
	return light_at(hour_of_day())


static func light_at(hour: float) -> Color:
	var h := fposmod(hour, 24.0)
	for i in range(1, LIGHT_KEYS.size()):
		if h <= LIGHT_KEYS[i]:
			var t := (h - LIGHT_KEYS[i - 1]) / (LIGHT_KEYS[i] - LIGHT_KEYS[i - 1])
			return LIGHT_COLORS[i - 1].lerp(LIGHT_COLORS[i], t)
	return LIGHT_COLORS[LIGHT_COLORS.size() - 1]
