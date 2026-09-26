extends "res://tests/harness.gd"

## Navigation (scripts/world/navigation.gd, §4.1 step 2) on small made-up
## grids, without the world scene: A* paths step between neighbours over
## walkable tiles only and never cut a corner, go round walls, stop at the
## closest tile when the goal can't be reached (or next to it with `near`);
## string-pulling keeps only the turns a straight walk can't skip; the
## nearest walkable tile. Run via tests/run_tests.sh.

const Nav := preload("res://scripts/world/navigation.gd")
const TILE := 16.0


## Every step moves to a walkable neighbour, and a diagonal step has both
## tiles beside it walkable.
func _valid(from: Vector2i, path: Array[Vector2i], walkable: Callable) -> bool:
	var prev := from
	for t in path:
		var step := t - prev
		if not walkable.call(t) or maxi(absi(step.x), absi(step.y)) != 1:
			return false
		if step.x != 0 and step.y != 0 and not (walkable.call(prev + Vector2i(step.x, 0)) and walkable.call(prev + Vector2i(0, step.y))):
			return false
		prev = t
	return true


func _init() -> void:
	var open := func(_t: Vector2i) -> bool: return true
	# A wall at x = 5 from y = -20 to 20, with a gap at y = 8.
	var wall := func(t: Vector2i) -> bool: return not (t.x == 5 and absi(t.y) <= 20 and t.y != 8)
	# The goal (10, 0) sealed in a ring of water 2 tiles out.
	var sealed := func(t: Vector2i) -> bool: return maxi(absi(t.x - 10), absi(t.y)) != 2

	var straight: Array[Vector2i] = Nav.find_path(Vector2i.ZERO, Vector2i(5, 3), open)
	check(straight.size() == 5 and straight[-1] == Vector2i(5, 3) and _valid(Vector2i.ZERO, straight, open),
		"open ground: %d steps (octile distance) to the goal" % straight.size())

	var around: Array[Vector2i] = Nav.find_path(Vector2i(0, 0), Vector2i(10, 0), wall)
	check(not around.is_empty() and around[-1] == Vector2i(10, 0) and around.has(Vector2i(5, 8)) and _valid(Vector2i.ZERO, around, wall),
		"a wall: the path goes through its gap (%d steps), never through it or past its corners" % around.size())

	var outside: Array[Vector2i] = Nav.find_path(Vector2i(0, 0), Vector2i(10, 0), sealed)
	var end: Vector2i = outside[-1] if not outside.is_empty() else Vector2i.ZERO
	check(_valid(Vector2i.ZERO, outside, sealed) and end == Vector2i(7, 0),
		"an unreachable goal: the path stops at the closest tile outside the ring (%s)" % end)

	var water := func(t: Vector2i) -> bool: return t != Vector2i(6, 0)
	var near: Array[Vector2i] = Nav.find_path(Vector2i(0, 0), Vector2i(6, 0), water, true)
	check(not near.is_empty() and near[-1] == Vector2i(5, 0) and _valid(Vector2i.ZERO, near, water),
		"walking up to a blocked tile (near): stops beside it at %s" % [near[-1] if not near.is_empty() else null])

	var centres := func(path: Array[Vector2i]) -> Array[Vector2]:
		var points: Array[Vector2] = []
		for t in path:
			points.append((Vector2(t) + Vector2(0.5, 0.5)) * TILE)
		return points
	var start := Vector2(0.5, 0.5) * TILE
	var free: Array[Vector2] = Nav.smooth_path(start, centres.call(straight), open, TILE)
	var turns: Array[Vector2] = Nav.smooth_path(start, centres.call(around), wall, TILE)
	var turns_ok: bool = turns[-1] == centres.call(around)[-1]
	var from := start
	for p in turns:
		turns_ok = turns_ok and Nav.walkable_line(from, p, wall, TILE)
		from = p
	check(free.size() == 1 and free[0] == centres.call(straight)[-1] and turns.size() > 1 and turns.size() < around.size() and turns_ok,
		"string-pulling: open ground is one straight walk; round the wall %d of %d points, each leg over walkable ground" % [turns.size(), around.size()])
	check(not Nav.walkable_line(start, (Vector2(10, 0.5)) * TILE, wall, TILE), "a straight walk through the wall is not walkable")

	check(Nav.nearest_walkable(Vector2i(3, 3), open) == Vector2i(3, 3) and Nav.nearest_walkable(Vector2i(5, 0), wall) in [Vector2i(4, 0), Vector2i(6, 0), Vector2i(4, -1), Vector2i(6, -1), Vector2i(4, 1), Vector2i(6, 1)]
		and Nav.nearest_walkable(Vector2i(1, 1), func(_t): return false) == Vector2i(1, 1),
		"nearest walkable tile: itself, a neighbour off the wall, or the tile itself when nothing is walkable")

	finish()
