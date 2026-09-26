extends RefCounted

## Which chunks the camera wants and the jobs that build them.
##
## Phase 17 streaming: a chunk's content (image, markers, labels) is built by
## a job, nearest chunk first, and shown by the main thread a few per frame,
## so crossing a chunk boundary never stalls a frame on a whole row of
## chunks. On desktop the jobs run on one worker thread; where threads are
## unavailable (the web export has thread_support off) they run on the main
## thread, a few small steps per frame (INLINE_BUDGET_USEC). A job's steps
## come from the ChunkBuilder and run holding the generation context's
## mutex; its finished data goes to `apply` (ChunkPresenter) on the main
## thread, and chunks that leave the unload radius to `unload`. The queue
## fields are guarded by _queue_mutex.

const GameConstants := preload("res://scripts/game_constants.gd")
const GenerationContextScript := preload("res://scripts/world/generation_context.gd")
const ChunkBuilderScript := preload("res://scripts/world/chunk_builder.gd")

const TILE_SIZE := GameConstants.TILE_SIZE  # world pixels per tile (scripts/game_constants.gd)
const CHUNK_SIZE := GenerationContextScript.CHUNK_SIZE
const MIN_LOAD_RADIUS := 4     # floor on load radius even when zoomed in
const UNLOAD_BUFFER := 2       # extra chunks beyond load radius before freeing (hysteresis)

## LOD: at low zoom, sample each chunk on a coarser grid (1 sample per
## lod_step^2 tiles instead of per-tile) and let the Sprite2D's scale
## stretch it back to the same world-space footprint - same idea as a
## mipmap. Zoomed out means MORE chunks are needed to cover the screen, not
## fewer, so without this every additional chunk still paid full per-tile
## WorldGen.sample() cost (~30-40 noise calls each after all the biome-
## variety fields) even though individual tiles aren't perceivable at that
## zoom anyway. Steps must evenly divide CHUNK_SIZE.
const LOD_THRESHOLDS := [
	{"zoom": 1.0, "step": 1},
	{"zoom": 0.5, "step": 2},
	{"zoom": 0.25, "step": 4},
	{"zoom": 0.0, "step": 8},
]
const LOD_HYSTERESIS := 0.05

## Without a worker thread: time per frame spent on chunk job steps on the
## main thread (at least one step per frame while any are queued).
const INLINE_BUDGET_USEC := 5000
## Time per frame spent turning finished chunk jobs into nodes (at least one).
const APPLY_BUDGET_USEC := 3000

var _builder: ChunkBuilderScript
var _ctx: GenerationContextScript
var _camera: Callable  # -> [world position to load around, zoom, viewport size]
var _apply: Callable   # (data) main thread: show one finished job
var _unload: Callable  # (chunk) main thread: drop a chunk's nodes

var _last_center: Vector2i = Vector2i(1 << 30, 1 << 30)  # force first update
var _last_load_radius: int = -1
var _last_lod_step: int = -1

# _epoch is bumped by a view or LOD change; a loaded chunk whose _shown_epoch
# differs is stale and gets rebuilt. Only the main thread writes _epoch
# (under _queue_mutex).
var _epoch: int = 0
var _shown_epoch: Dictionary = {}   # Vector2i chunk -> epoch its content was built for (every shown chunk)
var _shown_image: Dictionary = {}   # Vector2i chunk -> [ChunkBuilder.image_key(), lod] of the image on screen
var _jobs_dirty: bool = false       # rebuild the job list on the next refresh()
var _jobs: Array = []               # [chunk, epoch, lod step, area], nearest last (popped from the back)
var _in_flight: Dictionary = {}     # chunk -> epoch of a job taken but not yet applied
var _results: Array = []            # finished job data for the main thread
var _ready_results: Array = []      # main thread: taken from _results, not yet applied
var _inline_job: Dictionary = {}     # main thread without a worker: the job being stepped (see _run_inline_steps)
var _queue_mutex := Mutex.new()     # guards _jobs, _in_flight, _results, _epoch writes, _stop_worker, _longest_step_usec
var _semaphore := Semaphore.new()
var _worker: Thread
var _stop_worker: bool = false
var _longest_step_usec := 0  # debug overlay: since take_perf_counters()
var _chunks_shown := 0  # debug overlay: chunks applied so far


func _init(builder: ChunkBuilderScript, context: GenerationContextScript, camera: Callable, apply: Callable, unload: Callable) -> void:
	_builder = builder
	_ctx = context
	_camera = camera
	_apply = apply
	_unload = unload


## Starts the worker thread (threaded = false keeps every job on the main
## thread, stepped from process()).
func start(threaded: bool) -> void:
	if threaded:
		_worker = Thread.new()
		_worker.start(_worker_loop)


func stop() -> void:
	if _worker == null:
		return
	_queue_mutex.lock()
	_stop_worker = true
	_queue_mutex.unlock()
	_semaphore.post()
	_worker.wait_to_finish()
	_worker = null


func has_worker() -> bool:
	return _worker != null


## Main thread, once a frame: follows the camera, steps jobs without a
## worker, and shows finished ones.
func process() -> void:
	refresh()
	if _worker == null:
		_run_inline_steps(Time.get_ticks_usec() + INLINE_BUDGET_USEC)
	_apply_results(APPLY_BUDGET_USEC)


## Keeps the job list in step with the camera: a LOD change makes every
## loaded chunk stale, a new center or radius changes which chunks are wanted.
func refresh() -> void:
	var camera: Array = _camera.call()
	var lod_step := current_lod_step(camera[1])
	if lod_step != _last_lod_step:
		_last_lod_step = lod_step
		invalidate()

	var center := chunk_of(camera[0])
	var load_radius := _load_radius(camera[1], camera[2])
	if center == _last_center and load_radius == _last_load_radius and not _jobs_dirty:
		return
	_last_center = center
	_last_load_radius = load_radius
	_update_chunks(center, load_radius)


## View or LOD changed: every loaded chunk is stale. It keeps showing its old
## content until its rebuild (queued with the missing chunks) replaces it.
## Content was reloaded: no image on screen can be kept (review P4).
func forget_images() -> void:
	_shown_image.clear()


func invalidate() -> void:
	_queue_mutex.lock()
	_epoch += 1
	_queue_mutex.unlock()
	_jobs_dirty = true


## Drops every shown chunk (a new seed); they stream back in on the next
## refresh().
func unload_all() -> void:
	for c in _shown_epoch.keys():
		_unload_chunk(c)
	invalidate()


## Tests and benchmarks: finishes every chunk job for the current camera,
## view and LOD now (on this thread, alongside the worker) and applies the
## results, as if enough frames had passed. Afterwards the worker is idle
## until something changes, so generation functions are safe to call.
func flush() -> void:
	while true:
		refresh()
		while not _inline_job.is_empty():
			if _step_job(_inline_job):
				_inline_job = {}
		while _run_next_job():
			pass
		_apply_results(-1)
		if not has_pending():
			return
		OS.delay_usec(200)  # the worker is finishing a chunk


## The debug overlay's counters (review W4): the longest job step since the
## last call (then reset), chunks queued or being built, and chunks shown
## so far.
func take_perf_counters() -> Dictionary:
	_queue_mutex.lock()
	var counters := {"longest_step_usec": _longest_step_usec, "queued": _jobs.size() + _in_flight.size(), "shown": _chunks_shown}
	_longest_step_usec = 0
	_queue_mutex.unlock()
	return counters


func has_pending() -> bool:
	_queue_mutex.lock()
	var busy := not (_jobs.is_empty() and _in_flight.is_empty() and _results.is_empty())
	_queue_mutex.unlock()
	return busy or not _ready_results.is_empty() or not _inline_job.is_empty() or _jobs_dirty


## Enough chunks to cover the view at `zoom` (whatever it is), plus a floor
## so a fully zoomed-in camera still has a comfortable buffer.
static func _load_radius(zoom: float, viewport_size: Vector2) -> int:
	var half_extent_px := (viewport_size / zoom) * 0.5
	var half_diagonal_px := half_extent_px.length()
	var chunk_px := CHUNK_SIZE * TILE_SIZE
	var needed := ceili(half_diagonal_px / chunk_px) + 1
	return maxi(MIN_LOAD_RADIUS, needed)


func current_lod_step(zoom: float) -> int:
	return lod_step_for(zoom, _last_lod_step)


## The LOD step for `zoom`, coming from step `current` (-1: none yet). A
## threshold must be passed by LOD_HYSTERESIS (5 %) before the step changes,
## so a pinch hovering at a threshold doesn't rebuild every loaded chunk on
## each crossing (review W5).
static func lod_step_for(zoom: float, current: int) -> int:
	var plain := _lod_step_at(zoom)
	if current < 0 or plain == current:
		return plain
	return _lod_step_at(zoom / (1.0 + LOD_HYSTERESIS) if plain < current else zoom / (1.0 - LOD_HYSTERESIS))


static func _lod_step_at(zoom: float) -> int:
	for entry in LOD_THRESHOLDS:
		if zoom >= entry["zoom"]:
			return entry["step"]
	return 1


static func chunk_of(world_pos: Vector2) -> Vector2i:
	var tile := Vector2i(floori(world_pos.x / TILE_SIZE), floori(world_pos.y / TILE_SIZE))
	return Vector2i(floori(float(tile.x) / CHUNK_SIZE), floori(float(tile.y) / CHUNK_SIZE))


func _unload_chunk(chunk_coord: Vector2i) -> void:
	_shown_epoch.erase(chunk_coord)
	_shown_image.erase(chunk_coord)
	_unload.call(chunk_coord)


## Unloads chunks beyond load_radius + UNLOAD_BUFFER (hysteresis) and queues
## a job for every chunk within load_radius that is missing or stale, nearest
## first. A chunk whose job for the current epoch is already running isn't
## queued again.
func _update_chunks(center: Vector2i, load_radius: int) -> void:
	_jobs_dirty = false
	var unload_radius := load_radius + UNLOAD_BUFFER
	for c in _shown_epoch.keys():
		if Vector2(c - center).length() > unload_radius:
			_unload_chunk(c)

	var wanted: Array[Vector2i] = []
	for cy in range(center.y - load_radius, center.y + load_radius + 1):
		for cx in range(center.x - load_radius, center.x + load_radius + 1):
			var c := Vector2i(cx, cy)
			if _shown_epoch.get(c, -1) != _epoch:
				wanted.append(c)
	wanted.sort_custom(_farther_first.bind(center))
	var area := (2 * load_radius + 1) * (2 * load_radius + 1)

	# Review P4: a chunk already showing the image this view would bake (the
	# same image key and LOD - World and Terrain Only, say) keeps it; its job
	# builds only the rest.
	var image_key := _builder.image_key()
	_queue_mutex.lock()
	_jobs.clear()
	for c in wanted:
		if _in_flight.get(c, -1) != _epoch:
			var keep_image: bool = _shown_image.get(c) == [image_key, _last_lod_step]
			_jobs.append([c, _epoch, _last_lod_step, area, image_key, keep_image])
	var has_jobs := not _jobs.is_empty()
	_queue_mutex.unlock()
	if has_jobs and _worker != null:
		_semaphore.post()


## Job order: farthest from center first (jobs are popped from the back), ties
## by position so the order is deterministic.
static func _farther_first(a: Vector2i, b: Vector2i, center: Vector2i) -> bool:
	var da := (a - center).length_squared()
	var db := (b - center).length_squared()
	if da != db:
		return da > db
	return a.y > b.y or (a.y == b.y and a.x > b.x)


## Takes the nearest queued chunk and runs its whole job (every step),
## leaving the data in _results for _apply_results() - the worker's and
## flush()'s way. Returns false when there was nothing to take (or the
## worker is stopping).
func _run_next_job() -> bool:
	var job := _take_job()
	if job.is_empty():
		return false
	var state := _new_job_state(job, false)
	while not _step_job(state):
		pass
	return true


## Main thread without a worker: runs job steps (taking new jobs as needed)
## until the deadline - at least one step, so a frame spends at most about
## one step past its budget.
func _run_inline_steps(deadline: int) -> void:
	while true:
		if _inline_job.is_empty():
			var job := _take_job()
			if job.is_empty():
				return
			_inline_job = _new_job_state(job, true)
		if _step_job(_inline_job):
			_inline_job = {}
		if Time.get_ticks_usec() >= deadline:
			return


## Pops the nearest queued job for the current epoch and marks it in flight
## (jobs queued before a view/LOD change are dropped - their rebuild is
## queued too); [] if there is none, or the worker is stopping.
func _take_job() -> Array:
	var job: Array = []
	_queue_mutex.lock()
	while not _jobs.is_empty() and not _stop_worker:
		var candidate: Array = _jobs.pop_back()
		if candidate[1] == _epoch:
			_in_flight[candidate[0]] = candidate[1]
			job = candidate
			break
	_queue_mutex.unlock()
	return job


## A taken job ([chunk, epoch, lod step, area]) about to run: its data (filled
## by the steps) and step list (planned by the first _step_job(); fine =
## the main-thread fallback's finer steps, see ChunkBuilder.job_steps()).
func _new_job_state(job: Array, fine: bool) -> Dictionary:
	var image: Image = null  # null: keep the image on screen (review P4)
	if not job[5]:
		_ctx.mutex.lock()  # the image format follows the view mode (review C2)
		image = _builder.new_image(job[2])
		_ctx.mutex.unlock()
	var data := {"chunk": job[0], "epoch": job[1], "lod": job[2], "area": job[3], "image": image, "image_key": job[4]}
	return {"data": data, "steps": [], "planned": false, "next": 0, "fine": fine}


## Runs one step of a job (holding _ctx.mutex). Returns true when the job
## is over: finished, with its data queued in _results, or abandoned because
## a view/LOD/seed change made it stale (its rebuild is queued already).
func _step_job(state: Dictionary) -> bool:
	var data: Dictionary = state["data"]
	_queue_mutex.lock()
	var stale: bool = data["epoch"] != _epoch
	_queue_mutex.unlock()
	if not stale:
		_ctx.mutex.lock()
		_ctx.gen_area = data["area"]
		if not state["planned"]:
			state["steps"] = _builder.job_steps(data, state["fine"])
			state["planned"] = true
		var steps: Array = state["steps"]
		if state["next"] < steps.size():
			var began := Time.get_ticks_usec()
			(steps[state["next"]] as Callable).call()
			state["next"] += 1
			var took := Time.get_ticks_usec() - began
			_queue_mutex.lock()
			_longest_step_usec = maxi(_longest_step_usec, took)
			_queue_mutex.unlock()
		_ctx.mutex.unlock()
		if state["next"] < steps.size():
			return false

	_queue_mutex.lock()
	if stale:
		if _in_flight.get(data["chunk"], -1) == data["epoch"]:
			_in_flight.erase(data["chunk"])
	else:
		_results.append(data)
	_queue_mutex.unlock()
	return true


func _worker_loop() -> void:
	while true:
		_semaphore.wait()
		_queue_mutex.lock()
		var stop := _stop_worker
		_queue_mutex.unlock()
		if stop:
			return
		while _run_next_job():
			pass


## Main thread: shows finished jobs until budget_usec is spent (at least one;
## negative = no limit). A result built for an older view/LOD, or for a chunk
## that has since left the unload radius, is dropped.
func _apply_results(budget_usec: int) -> void:
	_queue_mutex.lock()
	_ready_results.append_array(_results)
	_results.clear()
	_queue_mutex.unlock()

	var deadline := Time.get_ticks_usec() + budget_usec
	var i := 0
	while i < _ready_results.size():
		var data: Dictionary = _ready_results[i]
		i += 1
		var chunk_coord: Vector2i = data["chunk"]
		_queue_mutex.lock()
		if _in_flight.get(chunk_coord, -1) == data["epoch"]:
			_in_flight.erase(chunk_coord)
		_queue_mutex.unlock()
		if data["epoch"] != _epoch or Vector2(chunk_coord - _last_center).length() > _last_load_radius + UNLOAD_BUFFER:
			continue
		var shown_image := [data["image_key"], data["lod"]]
		if data["image"] == null and _shown_image.get(chunk_coord) != shown_image:
			_jobs_dirty = true  # the kept image went (the chunk was unloaded): rebuild it whole
			continue
		_apply.call(data)
		_shown_epoch[chunk_coord] = data["epoch"]
		_shown_image[chunk_coord] = shown_image
		_chunks_shown += 1
		if budget_usec >= 0 and Time.get_ticks_usec() >= deadline:
			break
	_ready_results = _ready_results.slice(i)
