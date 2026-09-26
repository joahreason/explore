class_name SunShadow
extends RefCounted

## Where cast shadows fall at an in-game hour (shaders/cast_shadow.gdshader):
## the sun crosses from east to west between SUNRISE and SUNSET, so shadows
## start long and pointing west (left), shorten towards noon and end long
## and pointing east; at night the moon does the same, much fainter. Both
## fade out towards their horizon, so the handover at dawn and dusk is
## seamless. Screen "down" is towards the viewer: shadows always lean a
## little that way, so they show below the object rather than behind it.

const SUNRISE := 6.0
const SUNSET := 18.0
const DAY_DARKNESS := 0.32
const NIGHT_DARKNESS := 0.12
## Shadow length per pixel of object height at the highest sun, and the cap
## near the horizon.
const NOON_LENGTH := 0.45
const MAX_LENGTH := 1.3


## Vector3(cast_dir.x, cast_dir.y, darkness) for an hour (0..24): cast_dir is
## the shadow's offset per pixel of height (x east, y towards the viewer).
static func at(hour: float) -> Vector3:
	var h := fposmod(hour, 24.0)
	var is_day := h >= SUNRISE and h < SUNSET
	# 0 at the source's rising, 1 at its setting (sun by day, moon by night).
	var t := (h - SUNRISE) / (SUNSET - SUNRISE) if is_day else fposmod(h - SUNSET, 24.0) / (24.0 - (SUNSET - SUNRISE))
	var elevation := sin(PI * t)
	var length := minf(NOON_LENGTH / maxf(elevation, 0.05), MAX_LENGTH)
	# Rising in the east throws shadows west (-x); setting in the west, east.
	var sideways := -cos(PI * t) * length
	var towards_viewer := 0.25 + 0.2 * minf(length, 1.0)
	var fade := smoothstep(0.0, 0.25, elevation)
	var darkness := (DAY_DARKNESS if is_day else NIGHT_DARKNESS) * fade
	return Vector3(sideways, towards_viewer, darkness)


## Pushes the shadow for an in-game time (minutes) into a cast-shadow material.
static func apply(material: ShaderMaterial, minutes: float) -> void:
	var s := at(fposmod(minutes, 1440.0) / 60.0)
	material.set_shader_parameter("cast_dir", Vector2(s.x, s.y))
	material.set_shader_parameter("darkness", s.z)
