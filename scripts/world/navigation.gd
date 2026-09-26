extends RefCounted

## Walking on the tile grid (§4.1 step 2, moved out of chunk_manager.gd):
## A* over tiles, string-pulling a walk, the nearest walkable tile. Pure:
## every function takes `walkable`, a Callable(tile: Vector2i) -> bool, so
## the caller decides what blocks (open water today; walls later:
## `is_walkable(t) and not structures.blocks(t)`) and holds whatever lock
## that needs.

## Max tiles A* expands per path: enough to route round a lake across the
## screen; beyond it the player heads for the closest tile found.
const MAX_PATH_NODES := 6000
const PATH_STEPS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]


## A* over tiles, 8 directions (no cutting a corner past water): the tiles
## to step through from `from` (excluded) to `to`, or to within one tile of
## it with `near` (walking up to a resource). If `to` can't be reached
## within MAX_PATH_NODES, the path to the closest tile explored.
static func find_path(from: Vector2i, to: Vector2i, walkable: Callable, near: bool = false) -> Array[Vector2i]:
	var done := func(t: Vector2i) -> bool:
		return t == to or (near and maxi(absi(t.x - to.x), absi(t.y - to.y)) <= 1)
	var came := {from: from}
	var cost := {from: 0.0}
	var open_f: Array[float] = [_octile(from, to)]
	var open_t: Array[Vector2i] = [from]
	var best := from
	var best_h := _octile(from, to)
	var expanded := 0
	while not open_t.is_empty() and expanded < MAX_PATH_NODES:
		var current: Vector2i = _heap_pop(open_f, open_t)
		if done.call(current):
			best = current
			break
		expanded += 1
		var h := _octile(current, to)
		if h < best_h:
			best_h = h
			best = current
		for step in PATH_STEPS:
			var next: Vector2i = current + step
			if not walkable.call(next):
				continue
			if step.x != 0 and step.y != 0 and not (walkable.call(current + Vector2i(step.x, 0)) and walkable.call(current + Vector2i(0, step.y))):
				continue
			var g: float = cost[current] + (1.41421356 if step.x != 0 and step.y != 0 else 1.0)
			if g < cost.get(next, INF):
				cost[next] = g
				came[next] = current
				_heap_push(open_f, open_t, g + _octile(next, to), next)
	var path: Array[Vector2i] = []
	var t := best
	while t != from:
		path.push_front(t)
		t = came[t]
	return path


## String-pulls a walk: drops every point the player can skip by walking
## straight to a later one over walkable ground (walkable_line()), so the
## walk is free rather than tile to tile. Points are world px.
static func smooth_path(start: Vector2, points: Array[Vector2], walkable: Callable, tile_size: float) -> Array[Vector2]:
	var result: Array[Vector2] = []
	var from := start
	var i := 0
	while i < points.size():
		var j := points.size() - 1
		while j > i and not walkable_line(from, points[j], walkable, tile_size):
			j -= 1
		result.append(points[j])
		from = points[j]
		i = j + 1
	return result


## Whether the straight walk from `a` to `b` (world px) stays on walkable
## tiles, with a little clearance either side so it never grazes a water
## corner.
static func walkable_line(a: Vector2, b: Vector2, walkable: Callable, tile_size: float) -> bool:
	var d := b - a
	var n := ceili(d.length() / (tile_size * 0.25)) + 1
	var side := d.orthogonal().normalized() * 3.0 if d.length() > 0.0 else Vector2.ZERO
	for k in n + 1:
		var p := a + d * (float(k) / n)
		for q in [p, p + side, p - side]:
			if not walkable.call(Vector2i(((q as Vector2) / tile_size).floor())):
				return false
	return true


## The walkable tile nearest `tile` (spiral search); `tile` itself if none
## within 64 tiles.
static func nearest_walkable(tile: Vector2i, walkable: Callable) -> Vector2i:
	if walkable.call(tile):
		return tile
	for r in range(1, 65):
		for dy in range(-r, r + 1):
			for dx in [-r, r] if absi(dy) != r else range(-r, r + 1):
				if walkable.call(tile + Vector2i(dx, dy)):
					return tile + Vector2i(dx, dy)
	return tile


static func _octile(a: Vector2i, b: Vector2i) -> float:
	var dx := absi(a.x - b.x)
	var dy := absi(a.y - b.y)
	return maxi(dx, dy) + 0.41421356 * mini(dx, dy)


static func _heap_push(f: Array[float], t: Array[Vector2i], priority: float, tile: Vector2i) -> void:
	f.append(priority)
	t.append(tile)
	var i := f.size() - 1
	while i > 0:
		var parent := (i - 1) / 2
		if f[parent] <= f[i]:
			break
		var pf := f[parent]
		f[parent] = f[i]
		f[i] = pf
		var pt := t[parent]
		t[parent] = t[i]
		t[i] = pt
		i = parent


static func _heap_pop(f: Array[float], t: Array[Vector2i]) -> Vector2i:
	var top := t[0]
	var last := f.size() - 1
	f[0] = f[last]
	t[0] = t[last]
	f.resize(last)
	t.resize(last)
	var i := 0
	while true:
		var l := i * 2 + 1
		var r := l + 1
		var m := i
		if l < f.size() and f[l] < f[m]:
			m = l
		if r < f.size() and f[r] < f[m]:
			m = r
		if m == i:
			break
		var mf := f[m]
		f[m] = f[i]
		f[i] = mf
		var mt := t[m]
		t[m] = t[i]
		t[i] = mt
		i = m
	return top
