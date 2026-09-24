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

var minutes: float = START_MINUTES


func advance(real_seconds: float) -> void:
	minutes += maxf(real_seconds, 0.0) * MINUTES_PER_SECOND


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
