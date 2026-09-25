extends SceneTree

## Panning benchmark: per-frame time while the camera pans at a steady speed
## at the default zoom, with the real world.tscn (seed 4242) - what a player
## feels as stutter when chunks stream in. Not a pass/fail suite
## (run_tests.sh only runs test_*):
##
##   $GODOT --headless --path . --script res://tests/bench_pan.gd
##
## BENCH_VIEWS=MATERIAL,RESOURCES picks the views (ViewMode names; default
## MATERIAL,RESOURCES), BENCH_SPEED world px per frame (default 3 = 12 screen
## px/frame at zoom 4, ~720 px/s at 60 fps), BENCH_THREADED=0 generates on
## the main thread (the web export's fallback). Each run pans 6 chunks east
## from a start the world has not generated yet, then 6 chunks diagonally.
## "holes" = frames in which a chunk inside the camera view wasn't loaded yet
## (streaming fell behind the pan). "work" = Godot's own per-frame process
## time (Performance.TIME_PROCESS): main-thread work only. Frame times include
## the idle sleep between headless frames, which on Windows can round up to
## the ~15.6 ms default timer tick - compare "work" across machines and runs.

const STARTS := {
	"forest": Vector2(0, 0),
	"coast": Vector2(19946, 20042) * 12,
}
const PAN_CHUNKS := 6


func _init() -> void:
	var world: Node2D = load("res://world.tscn").instantiate()
	world.world_seed = 4242
	if OS.get_environment("BENCH_THREADED") == "0" and "threaded_generation" in world:
		world.threaded_generation = false
	root.add_child(world)
	await process_frame
	await process_frame

	var CM = world.get_script()
	var cam: Node2D = world.get_node("CameraRig")
	cam._player = null  # the benchmark pans the camera itself; no following
	var speed := float(OS.get_environment("BENCH_SPEED")) if OS.get_environment("BENCH_SPEED") != "" else 3.0
	var views := (OS.get_environment("BENCH_VIEWS") if OS.get_environment("BENCH_VIEWS") != "" else "MATERIAL,RESOURCES").split(",")
	var chunk_px: float = world.CHUNK_SIZE * world.TILE_SIZE
	var offset := 0.0
	for view_name in views:
		world.set_view_mode(CM.ViewMode.MATERIAL)
		world.set_view_mode(CM.ViewMode[view_name])
		for start_name in STARTS:
			for dir in [Vector2(1, 0), Vector2(1, 1).normalized()]:
				# Fresh ground for every run, so no run reuses another's caches.
				offset += 40.0 * chunk_px
				cam.global_position = STARTS[start_name] + Vector2(0, offset)
				await _settle(world)
				var frames := PackedFloat64Array()
				var work := PackedFloat64Array()
				var holes := 0
				var steps := int(PAN_CHUNKS * chunk_px / speed)
				var t_prev := Time.get_ticks_usec()
				for i in steps:
					cam.global_position += dir * speed
					await process_frame
					var now := Time.get_ticks_usec()
					frames.append((now - t_prev) / 1000.0)
					work.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
					t_prev = now
					holes += int(_view_has_hole(world, cam))
				_report("%s %s %s" % [view_name, start_name, "east" if dir.y == 0 else "diag"], frames, holes, work)
	quit()


## Lets the world finish loading around a teleported camera before timing.
func _settle(world: Node2D) -> void:
	for i in 3:
		await process_frame
	if world.has_method("has_pending_chunks"):
		while world.has_pending_chunks():
			await process_frame


## True if a chunk overlapping the camera's view isn't loaded.
func _view_has_hole(world: Node2D, cam: Node2D) -> bool:
	var camera: Camera2D = cam.get_node("Camera2D")
	var half: Vector2 = world.get_viewport().get_visible_rect().size / camera.zoom * 0.5
	var c0: Vector2i = world._chunk_of(cam.global_position - half)
	var c1: Vector2i = world._chunk_of(cam.global_position + half)
	for cy in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			if not world._loaded_chunks.has(Vector2i(cx, cy)):
				return true
	return false


func _report(label: String, frames: PackedFloat64Array, holes: int, work: PackedFloat64Array) -> void:
	var work_sorted := work.duplicate()
	work_sorted.sort()
	var sorted := frames.duplicate()
	sorted.sort()
	var total := 0.0
	var over_16 := 0
	var over_33 := 0
	for f in frames:
		total += f
		over_16 += int(f > 16.7)
		over_33 += int(f > 33.3)
	print("BENCH %-26s frames %4d  mean %5.2f  p50 %5.2f  p99 %6.1f  max %6.1f ms  >16.7ms %3d  >33ms %3d  holes %3d  work p50 %5.2f p99 %5.2f max %6.1f ms" % [
		label, frames.size(), total / frames.size(), sorted[frames.size() / 2],
		sorted[int(frames.size() * 0.99)], sorted[-1], over_16, over_33, holes, work_sorted[work.size() / 2], work_sorted[int(work.size() * 0.99)], work_sorted[-1]])
