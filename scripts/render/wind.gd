class_name Wind
extends RefCounted

## World wind for the sway shader (shaders/sway.gdshader): a direction and
## strength that drift slowly with the in-game clock (so a paused game holds
## still, fast-forward changes the weather faster, rewinding brings the same
## wind back), plus an animation phase that runs with real time x the clock
## rate, capped at +-MAX_ANIMATION_RATE so fast-forward doesn't flicker.
## No weather yet: strength never drops to calm or rises to a storm.

const MAX_ANIMATION_RATE := 4.0
## Strength range (0..1) the drift stays within.
const STRENGTH_MIN := 0.35
const STRENGTH_MAX := 1.0

var phase: float = 0.0


## Advances the animation phase; clock_rate = GameClock.rate().
func advance(real_seconds: float, clock_rate: float) -> void:
	phase += maxf(real_seconds, 0.0) * clampf(clock_rate, -MAX_ANIMATION_RATE, MAX_ANIMATION_RATE)


## Unit wind direction at an in-game time (minutes): wanders around a
## mostly westerly heading (blowing east) over hours.
static func direction_at(minutes: float) -> Vector2:
	var hours := minutes / 60.0
	var angle := 0.6 * sin(hours * 0.21) + 0.35 * sin(hours * 0.57 + 1.3)
	return Vector2.from_angle(angle)


## Strength (STRENGTH_MIN..STRENGTH_MAX) at an in-game time: slow swells over
## a few hours.
static func strength_at(minutes: float) -> float:
	var hours := minutes / 60.0
	var s := 0.5 + 0.3 * sin(hours * 0.9) + 0.2 * sin(hours * 2.3 + 0.7)
	return lerpf(STRENGTH_MIN, STRENGTH_MAX, clampf(s, 0.0, 1.0))


## Pushes the current wind into the sway material's uniforms.
func apply(material: ShaderMaterial, minutes: float) -> void:
	material.set_shader_parameter("wind_phase", phase)
	material.set_shader_parameter("wind_dir", direction_at(minutes))
	material.set_shader_parameter("wind_strength", strength_at(minutes))
