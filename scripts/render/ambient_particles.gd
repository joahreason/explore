extends Node2D

## Ambient particles (polish pass 2), chosen by where and when they are:
##   firefly   - warm, damp or sheltered ground at night, spring-summer
##   pollen    - sunny open vegetation by day, spring-summer
##   butterfly - warm sunny meadows by day, spring-summer (fewer)
##   leaf      - under canopy in autumn (a few on windy summer days too)
##   sand      - dry, bare country when the wind is up
##   snow      - cold places, and anywhere cool in winter
## weights() is the pure rule table (tests use it); the node keeps a pool of
## live particles inside the camera view, spawning at random visible tiles
## and picking a kind by that tile's weights - so particles gather where the
## world supports them. Motion follows the in-game clock (paused or
## rewinding = frozen, capped at x4 like the wind). Only in the gameplay
## views, and not when zoomed far out. Fireflies are drawn brighter than the
## night tint so they glow; everything else is tinted like the world.

const KINDS := ["firefly", "pollen", "butterfly", "leaf", "sand", "snow"]
## Live particles per 1000 visible tiles, and the cap.
const DENSITY := 30.0
const MAX_PARTICLES := 140
## Spawn attempts per real second (each may find no suitable kind).
const ATTEMPTS_PER_SECOND := 40.0
const MIN_ZOOM := 1.0
const MAX_RATE := 4.0

const BUTTERFLY_COLORS := [Color(1, 1, 1), Color(1, 0.85, 0.3), Color(1, 0.6, 0.2), Color(0.55, 0.7, 1.0)]
const LEAF_COLORS := [Color(0.9, 0.55, 0.15), Color(0.85, 0.35, 0.12), Color(0.9, 0.75, 0.25), Color(0.6, 0.45, 0.2)]

## Live particles: parallel arrays (position/velocity in world px).
var _kind: PackedInt32Array = []
var _pos: PackedVector2Array = []
var _vel: PackedVector2Array = []
var _age: PackedFloat32Array = []
var _life: PackedFloat32Array = []
var _color: PackedColorArray = []
var _spawn_credit := 0.0
var _rng := RandomNumberGenerator.new()

@onready var _world := get_parent()
@onready var _camera: Camera2D = get_node("../CameraRig/Camera2D")


## Relative weight of each kind (KINDS) for an environment: hour (0..24),
## year (0..1, Seasons.year_fraction), wind (0..1 strength), temperature
## (-1..1), moisture, vegetation, shade (0..1), water (bool), biome (String).
static func weights(env: Dictionary) -> Dictionary:
	var w := {}
	for k in KINDS:
		w[k] = 0.0
	if env.get("water", false):
		return w
	var hour: float = env["hour"]
	var year: float = env["year"]
	var temp: float = env["temperature"]
	var moist: float = env["moisture"]
	var veg: float = env["vegetation"]
	var shade: float = env["shade"]
	var wind: float = env["wind"]
	var biome: String = env.get("biome", "")
	var night := _band(hour, GameClock.NIGHT_CREATURE_HOURS)  # 1 deep night, fading at dusk/dawn
	var day := _band(hour, GameClock.DAY_CREATURE_HOURS)
	var warm_season := 1.0 - smoothstep(0.45, 0.55, year)  # spring and summer
	var autumn := smoothstep(0.48, 0.55, year) * (1.0 - smoothstep(0.72, 0.78, year))
	var winter := smoothstep(0.72, 0.8, year)
	var open := 1.0 - smoothstep(0.2, 0.4, shade)
	w["firefly"] = night * warm_season * smoothstep(-0.2, 0.1, temp) * clampf(maxf(smoothstep(0.4, 0.6, moist), smoothstep(0.15, 0.35, shade)), 0.0, 1.0) * smoothstep(0.05, 0.15, veg)
	w["pollen"] = day * warm_season * open * smoothstep(0.1, 0.25, veg) * smoothstep(-0.2, 0.1, temp)
	w["butterfly"] = 0.4 * day * warm_season * open * smoothstep(0.15, 0.3, veg) * smoothstep(0.0, 0.25, temp)
	w["leaf"] = 1.2 * smoothstep(0.2, 0.4, shade) * (autumn + 0.15 * smoothstep(0.7, 0.9, wind) * warm_season)
	var dry := 1.0 - smoothstep(0.2, 0.35, moist)
	var bare := 1.0 - smoothstep(0.08, 0.2, veg)
	var desert := 1.0 if biome in ["Desert", "Badlands"] else dry * bare
	w["sand"] = desert * smoothstep(0.45, 0.75, wind)
	w["snow"] = 1.2 * maxf(1.0 - smoothstep(-0.35, -0.2, temp), winter * (1.0 - smoothstep(0.0, 0.15, temp)))
	return w


## hours is [start, start_full, end_full, end]: 1 inside [start_full,
## end_full] (wrapping past midnight), 0 outside [start, end], smooth ramps
## between.
static func _band(hour: float, hours: Array[float]) -> float:
	var start := hours[0]
	var start_full := hours[1]
	var end_full := hours[2]
	var end := hours[3]
	var h := fposmod(hour, 24.0)
	if start < end:
		return smoothstep(start, start_full, h) * (1.0 - smoothstep(end_full, end, h))
	# Wraps midnight: e.g. 20..22 up, 3..5 down.
	var up := smoothstep(start, start_full, h) if h >= 12.0 else 1.0
	var down := 1.0 - smoothstep(end_full, end, h) if h < 12.0 else 1.0
	return up * down


func count() -> int:
	return _kind.size()


func kinds_alive() -> Dictionary:
	var c := {}
	for k in _kind:
		c[KINDS[k]] = c.get(KINDS[k], 0) + 1
	return c


func _ready() -> void:
	_rng.seed = 1337


func _process(delta: float) -> void:
	var active: bool = _world.is_time_tinted_view() and _camera.zoom.x >= MIN_ZOOM
	if not active:
		if count() > 0:
			_clear()
			queue_redraw()
		return
	var rate := clampf(_world.clock.rate(), 0.0, MAX_RATE)
	var dt := delta * rate
	if dt > 0.0:
		_step(dt)
		_spawn(dt)
	queue_redraw()


func _visible_rect() -> Rect2:
	var view := get_viewport_rect().size / _camera.zoom
	return Rect2(_camera.get_screen_center_position() - view * 0.5, view)


func _spawn(dt: float) -> void:
	var view := _visible_rect()
	var tiles: float = view.get_area() / float(_world.TILE_SIZE * _world.TILE_SIZE)
	var target := mini(int(tiles / 1000.0 * DENSITY) + 4, MAX_PARTICLES)
	_spawn_credit += dt * ATTEMPTS_PER_SECOND
	while _spawn_credit >= 1.0:
		_spawn_credit -= 1.0
		if count() >= target:
			_spawn_credit = 0.0
			return
		var p := Vector2(_rng.randf_range(view.position.x, view.end.x), _rng.randf_range(view.position.y, view.end.y))
		var env: Dictionary = _world.ambient_env(Vector2i((p / _world.TILE_SIZE).floor()))
		if env.is_empty():
			continue  # generation busy this instant; try again later
		var w := weights(env)
		var total := 0.0
		for k in KINDS:
			total += w[k]
		# Most attempts should fail on unsuitable ground, not all succeed:
		# the weights are chances, so sparse conditions give sparse particles.
		var roll := _rng.randf() * maxf(total, 1.0)
		for i in KINDS.size():
			roll -= w[KINDS[i]]
			if roll < 0.0:
				_add(i, p, env)
				break


func _add(kind: int, p: Vector2, env: Dictionary) -> void:
	var wind_dir: Vector2 = env["wind_dir"]
	var wind: float = env["wind"]
	var v := Vector2.ZERO
	var life := 5.0
	var color := Color.WHITE
	match KINDS[kind]:
		"firefly":
			v = Vector2.from_angle(_rng.randf() * TAU) * 3.0
			life = _rng.randf_range(4.0, 8.0)
			color = Color(1.0, 1.0, 0.45)
		"pollen":
			v = wind_dir * (3.0 + 5.0 * wind)
			life = _rng.randf_range(4.0, 7.0)
			color = Color(1, 1, 0.9, 0.8)
		"butterfly":
			v = Vector2.from_angle(_rng.randf() * TAU) * 7.0
			life = _rng.randf_range(5.0, 9.0)
			color = BUTTERFLY_COLORS[_rng.randi() % BUTTERFLY_COLORS.size()]
		"leaf":
			v = wind_dir * (4.0 + 8.0 * wind) + Vector2(0, 6.0)
			life = _rng.randf_range(3.0, 5.0)
			color = LEAF_COLORS[_rng.randi() % LEAF_COLORS.size()]
		"sand":
			v = wind_dir * (22.0 + 20.0 * wind)
			life = _rng.randf_range(1.5, 3.0)
			color = Color(0.9, 0.8, 0.55, 0.7)
		"snow":
			v = Vector2(0, 8.0) + wind_dir * (3.0 + 6.0 * wind)
			life = _rng.randf_range(4.0, 7.0)
			color = Color(1, 1, 1, 0.9)
	_kind.append(kind)
	_pos.append(p)
	_vel.append(v)
	_age.append(0.0)
	_life.append(life)
	_color.append(color)


func _step(dt: float) -> void:
	# Particles that leave the view (camera moved away) are dropped.
	var keep := _visible_rect().grow(float(_world.TILE_SIZE) * 4.0)
	var i := 0
	while i < _kind.size():
		_age[i] += dt
		if _age[i] >= _life[i] or not keep.has_point(_pos[i]):
			_remove(i)
			continue
		var k: String = KINDS[_kind[i]]
		var t := _age[i]
		var v := _vel[i]
		match k:
			"firefly", "butterfly":
				# Wander: turn a little each step.
				v = v.rotated(_rng.randf_range(-2.0, 2.0) * dt)
			"leaf", "snow":
				v.x += sin(t * 2.5 + float(i)) * 6.0 * dt
		_vel[i] = v
		_pos[i] += v * dt
		i += 1


func _remove(i: int) -> void:
	_kind.remove_at(i)
	_pos.remove_at(i)
	_vel.remove_at(i)
	_age.remove_at(i)
	_life.remove_at(i)
	_color.remove_at(i)


func _clear() -> void:
	_kind.clear()
	_pos.clear()
	_vel.clear()
	_age.clear()
	_life.clear()
	_color.clear()


func _draw() -> void:
	var light: Color = _world.clock.light()
	for i in _kind.size():
		var k: String = KINDS[_kind[i]]
		var t := _age[i]
		var fade := smoothstep(0.0, 0.4, t) * (1.0 - smoothstep(_life[i] - 0.6, _life[i], t))
		var c := _color[i]
		var p := _pos[i].floor()
		match k:
			"firefly":
				# Undo the night tint so it glows, and blink.
				var glow := (0.5 + 0.5 * sin(t * 4.0 + float(i) * 1.7)) * fade
				c = Color(c.r / maxf(light.r, 0.05), c.g / maxf(light.g, 0.05), c.b / maxf(light.b, 0.05), glow)
				var halo := Color(c.r, c.g, c.b, glow * 0.35)
				draw_rect(Rect2(p + Vector2(-1, 0), Vector2(3, 1)), halo)
				draw_rect(Rect2(p + Vector2(0, -1), Vector2(1, 3)), halo)
				draw_rect(Rect2(p, Vector2(1, 1)), c)
			"butterfly":
				c.a *= fade
				var open := int(t * 10.0) % 2 == 0
				draw_rect(Rect2(p - Vector2(1, 0), Vector2(3 if open else 1, 1)), c)
			"leaf":
				c.a *= fade
				draw_rect(Rect2(p, Vector2(2, 2)), c)
			"sand":
				c.a *= fade
				draw_rect(Rect2(p, Vector2(4, 1)), c)
			"snow":
				c.a *= fade
				draw_rect(Rect2(p, Vector2(2, 2) if i % 3 == 0 else Vector2(1, 1)), c)
			_:
				c.a *= fade
				draw_rect(Rect2(p, Vector2(1, 1)), c)
