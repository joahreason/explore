extends Node2D

## Infinite chunk-based procedural world, deterministic per world_seed.
## Rendering here is a debug visualization only (flat colored tiles per
## WorldGen field sample) - the art tileset is intentionally not used yet;
## see scripts/gen/world_gen.gd and scripts/gen/terrain_surface.gd for the actual
## generation/coloring logic. This file ties the world's modules together
## (review §4.1): ChunkStreamer decides which chunks to build and runs their
## jobs (scripts/world/chunk_streamer.gd), ChunkBuilder builds each one's
## content, ChunkPresenter shows it. Threading rule: everything
## generation touches - _world_gen (and its water topology cache), the
## generation caches, the view mode, ResourceManager's static noise caches,
## ResourceDefinition.curve_plan - is only used while holding _ctx.mutex
## (held per job step), and the scene tree only on the main
## thread. Tests that call generation functions directly do it after
## flush_chunk_work(), which leaves the worker idle.

const TerrainSurfaceScript := preload("res://scripts/gen/terrain_surface.gd")
const BiomeClassifierScript := preload("res://scripts/gen/biome_classifier.gd")
const EnvironmentalStateScript := preload("res://scripts/gen/environmental_state.gd")
const ResourceManagerScript := preload("res://scripts/resources/resource_manager.gd")
const GameConstants := preload("res://scripts/game_constants.gd")
const ResourceMarkerChunkScript := preload("res://scripts/render/resource_marker_chunk.gd")
const ResourceInstanceScript := preload("res://scripts/resources/resource_instance.gd")
const WindScript := preload("res://scripts/render/wind.gd")
const HarvestEffectScript := preload("res://scripts/render/harvest_effect.gd")
const TentSleepEffectScript := preload("res://scripts/render/tent_sleep_effect.gd")
const WorldSessionScript := preload("res://scripts/world/world_session.gd")
const NavigationScript := preload("res://scripts/world/navigation.gd")
const ViewModesScript := preload("res://scripts/world/view_modes.gd")
const GenerationContextScript := preload("res://scripts/world/generation_context.gd")
const ChunkBuilderScript := preload("res://scripts/world/chunk_builder.gd")
const ChunkStreamerScript := preload("res://scripts/world/chunk_streamer.gd")
const ChunkPresenterScript := preload("res://scripts/world/chunk_presenter.gd")
const ResourcePickerScript := preload("res://scripts/world/resource_picker.gd")
const WorldTravelScript := preload("res://scripts/world/world_travel.gd")
## One material for every marker node: resource sprites sway in the wind by
## their sway value (see ChunkPresenter.marker_colors()); other draws are unaffected.
const SWAY_SHADER := preload("res://shaders/sway.gdshader")
## Cast shadows under sprites (their silhouettes, thrown by the sun or moon
## - SunShadow - and swaying with them); one material for every chunk.
const CAST_SHADOW_SHADER := preload("res://shaders/cast_shadow.gdshader")
const SunShadowScript := preload("res://scripts/render/sun_shadow.gd")
## Where the content .tres files live - reload_content() re-reads them all.
const CONTENT_DIR := "res://resources"
## What the world is made of - guild stack, World-view layers, deposits,
## farmland, ground materials, structures - as data (review A3).
const CONTENT: WorldContent = preload("res://resources/world_content.tres")

const TILE_SIZE := GameConstants.TILE_SIZE  # world pixels per tile (scripts/game_constants.gd)
const CHUNK_SIZE := 16         # tiles per chunk edge
const TERRAIN_SHADER := preload("res://shaders/terrain.gdshader")
const SeasonsScript := preload("res://scripts/render/seasons.gd")
## Every view in one table - label, colouring, placement layers, flags:
## scripts/world/view_modes.gd (review A2).
const ViewMode := ViewModesScript.ViewMode

## Assign a saved WorldGen.tres preset here to tune generation in the
## Inspector; if left empty a default-tuned WorldGen is created at runtime.
@export var world_gen_params: WorldGen
@export var world_seed: int = 1337
@export var target_path: NodePath
## The player (scripts/world/player.gd): taps walk it (see _on_map_tapped()), its
## position is saved per seed, biome travel moves it.
@export var player_path: NodePath
## Generate chunks on a worker thread where threads exist; off = always on
## the main thread (the web fallback), e.g. for debugging.
@export var threaded_generation: bool = true
## Phase 16: where each seed's gameplay changes are saved
## ("<dir>/<seed>.json"; user:// is the browser's persistent storage on web).
## Under a test harness (a scripted SceneTree, tests/*.gd) the default is
## NOT used - changes stay in memory - so tests never read or overwrite a
## player's saved harvests; a test that wants a file sets its own dir.
const DEFAULT_CHANGES_DIR := "user://world_changes"
@export var changes_dir: String = DEFAULT_CHANGES_DIR

@onready var chunks_root: Node2D = $Chunks
@onready var overlay_root: Node2D = $Overlay
@onready var resources_root: Node2D = $Resources
## Every chunk's cast shadows, drawn under all resource sprites.
@onready var shadows_root: Node2D = $ShadowLayer
@onready var _inspector_panel := $UI/TileInspector
@onready var _seed_input: LineEdit = $UI/SeedInput

var _target: Node2D
var _player: Node2D
## Sleeping in a camp tent (enter_tent()): the bouncing tent standing in
## for its marker (session.tent_tile), which ChunkPresenter.marker_node() leaves out.
var _tent_effect: Node2D
var _seed_text: String = ""  # raw seed text in effect, shown in _seed_input
## The player's session: clock, saved changes, tent (WorldSession). Its
## changes are written on the main thread under _ctx.mutex, read by
## generation under it and by marker building on the main thread.
var session = WorldSessionScript.new()
## Generation's WorldGen, landmark sites, caches and lock (review C2):
## scripts/world/generation_context.gd.
var _ctx: GenerationContextScript = GenerationContextScript.new()
## Builds each chunk job's image, label grids and placements as plain data:
## scripts/world/chunk_builder.gd.
var _builder: ChunkBuilderScript = ChunkBuilderScript.new(_ctx)
## Which chunks to build, their jobs and the worker thread (started in
## _ready()); and what is shown of them (made in _ready(), once the scene
## tree is there).
var _streamer: ChunkStreamerScript = ChunkStreamerScript.new(_builder, _ctx, _camera_view, _show_chunk, _hide_chunk)
var _presenter: ChunkPresenterScript
## What is under a point: scripts/world/resource_picker.gd (made in _ready()).
var _picker: ResourcePickerScript
## The "Go to" menu's searches: scripts/world/world_travel.gd.
var _travel: WorldTravelScript = WorldTravelScript.new()
## In-game time (session.clock): DayNight tints the world by it and the
## clock label shows it.
var clock:
	get: return session.clock
var wind = WindScript.new()
var sway_material := ShaderMaterial.new()
var shadow_material := ShaderMaterial.new()
var terrain_material := ShaderMaterial.new()
## The view and the Debug views' resource live on the chunk builder, which
## generation reads them from; set them under _ctx.mutex.
var _debug_resource: ResourceDefinition:
	get: return _builder.debug_resource
	set(value): _builder.debug_resource = value
var _view_mode: ViewMode:
	get: return _builder.view_mode
	set(value): _builder.view_mode = value
## "Go to biome" (travel_to_biome): searches run on their own thread with
## their own WorldGen copy, so they share nothing with chunk generation.
signal biome_travel_finished(biome: String, found: bool, cancelled: bool)
## set_view_mode() switched the view (review A4: listeners need not poll).
signal view_changed(mode: ViewMode)
## set_debug_resource() picked another resource for the Debug views.
signal debug_resource_changed(definition: ResourceDefinition)
func _ready() -> void:
	sway_material.shader = SWAY_SHADER
	shadow_material.shader = CAST_SHADOW_SHADER
	terrain_material.shader = TERRAIN_SHADER
	for material in [sway_material, shadow_material, terrain_material]:
		GameConstants.apply_to(material)
	_presenter = ChunkPresenterScript.new(
		{"chunks": chunks_root, "overlay": overlay_root, "resources": resources_root, "shadows": shadows_root},
		{"terrain": terrain_material, "sway": sway_material, "shadow": shadow_material}, session, _builder)
	_picker = ResourcePickerScript.new(_ctx, _builder, _presenter, session, get_resource_instance)
	world_seed = _resolve_world_seed()
	if world_gen_params != null:
		_ctx.world_gen = world_gen_params
	_ctx.configure(world_seed)
	if player_path != NodePath():
		_player = get_node(player_path)
		_player.set_shadow_material(shadow_material, shadows_root)
	_load_gameplay_state()

	# A guild's warnings include its members' (oak among them).
	for warning in CONTENT.curve_warnings():
		push_warning(warning)
	CONTENT.prepare()

	if _seed_text != "":
		_seed_input.text = _seed_text

	if target_path != NodePath():
		_target = get_node(target_path)
		_target.connect("info_clicked", _on_tile_clicked)
		_target.connect("map_tapped", _on_map_tapped)
		if _target.has_method("snap_to_player"):
			_target.snap_to_player()

	_streamer.start(threaded_generation and _threads_available())
	_streamer.refresh()


func _exit_tree() -> void:
	_travel.stop()
	_streamer.stop()


## Web only: a "?seed=" query param overrides the exported world_seed - set
## by ReloadButton/RandomizeButton/SeedInput's Enter from whatever's in the
## seed field (see _seed_from_text). If no param was given at all, a fresh
## random seed is generated instead of falling back to the fixed exported
## default, so every plain visit gets a different world, and written into
## the URL so a refresh keeps it. Elsewhere the
## exported world_seed is used (the seed UI regenerates in place instead -
## see regenerate()). Either way, _seed_text is left holding whatever seed
## ended up in effect, so _ready() can show it in the seed field.
func _resolve_world_seed() -> int:
	if not OS.has_feature("web"):
		_seed_text = str(world_seed)
		return world_seed

	var raw = JavaScriptBridge.eval(
		"new URLSearchParams(location.search).get('seed') || ''", true
	)
	var raw_str := str(raw) if raw != null else ""
	if raw_str == "":
		raw_str = str(randi())
		# Put it in the URL, so refreshing, bookmarking or sharing the page
		# gives the same world (and its save) - review W6.
		JavaScriptBridge.eval("history.replaceState(null, '', '?seed=%s' + location.hash)" % raw_str.uri_encode())
	_seed_text = raw_str
	return _seed_from_text(raw_str)


## A purely numeric seed is used directly (matches the exported int seed
## behavior everywhere else in this project); anything else (letters/spaces)
## is hashed to a deterministic int, so the same text always regenerates the
## same world.
static func _seed_from_text(text: String) -> int:
	return int(text) if text.is_valid_int() else text.hash()


## Desktop seed UI (SeedInput's Enter, RandomizeButton - via
## SeedReload.apply_seed()): switches to the seed in seed_text in place, empty
## = a fresh random one. Web reloads the page with ?seed= instead. Every
## loaded chunk belongs to the old world, so they are all dropped and stream
## back in nearest first; the per-seed generation caches are dropped too.
func regenerate(seed_text: String) -> void:
	var text := seed_text.strip_edges()
	if text == "":
		text = str(randi())
	_seed_text = text
	_seed_input.text = text
	_inspector_panel.visible = false  # it describes a tile of the old world

	_ctx.mutex.lock()  # generation reads world_seed and the caches
	_save_gameplay_state()  # the old seed's time, before switching
	world_seed = _seed_from_text(text)
	_ctx.configure(world_seed)
	_load_gameplay_state()
	_ctx.mutex.unlock()

	_streamer.unload_all()
	_travel.reset()  # a running search is looking at the old world
	if _target and _target.has_method("snap_to_player"):
		_target.snap_to_player()


## Desktop tuning (review X3, F5): re-reads every content .tres under
## CONTENT_DIR from disk into the already loaded instances
## (CACHE_MODE_REPLACE refreshes them in place, so the preloaded consts see
## the edits), drops everything derived from them - curve plans, the static
## noise caches, the generation caches - and rebuilds the loaded chunks.
## Edit and save a .tres, press F5, and see it in seconds. Returns the
## number of files reloaded.
func reload_content() -> int:
	# The "Go to" thread reads structure definitions without _ctx.mutex.
	if _travel.stop_for_reload():
		_finish_biome_travel()

	_ctx.mutex.lock()
	var paths := _content_paths(CONTENT_DIR)
	for path in paths:
		# REPLACE only sets what the file stores: a value put back to its
		# default (so no longer written) would keep the old one. Checked on 4.7.
		_reset_to_defaults(load(path))
		ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
	ResourceManagerScript._patch_noise_cache.clear()
	ResourceManagerScript._vein_noise_cache.clear()
	TerrainSurfaceScript._patch_noise_cache.clear()
	CONTENT.prepare(true)
	_ctx.clear()
	_ctx.mutex.unlock()

	_streamer.forget_images()
	_streamer.invalidate()
	print("Reloaded %d content files from %s" % [paths.size(), CONTENT_DIR])
	return paths.size()


static func _reset_to_defaults(resource: Resource) -> void:
	var script: Script = resource.get_script()
	if script == null:
		return
	for property in script.get_script_property_list():
		if property["usage"] & PROPERTY_USAGE_STORAGE:
			var value = script.get_property_default_value(property["name"])
			if value is Array:
				value = resource.get(property["name"]).duplicate()
				value.clear()
			resource.set(property["name"], value)


static func _content_paths(dir: String) -> PackedStringArray:
	var paths := PackedStringArray()
	for file in DirAccess.get_files_at(dir):
		if file.ends_with(".tres"):
			paths.append(dir.path_join(file))
	for sub in DirAccess.get_directories_at(dir):
		paths.append_array(_content_paths(dir.path_join(sub)))
	return paths


func _threads_available() -> bool:
	return not OS.has_feature("web") or OS.has_feature("threads")


## Biome travel dropdown: moves the camera to the nearest tile of `biome`
## (a BiomeClassifier base biome name) - or, if the camera already stands in
## that biome, to the nearest other patch of it; repeated trips to the same
## biome hop onward (see BiomeFinder). The search can take seconds, so it
## runs on a thread, or without threads (web, threaded_generation off) a
## slice per frame from _process() (WorldTravel); either way
## biome_travel_finished reports the outcome. Ignored while a search runs;
## cancel_biome_travel() stops one.
func travel_to_biome(biome: String) -> void:
	if is_finding_biome():
		return
	var pos: Vector2 = _player.tile_center(_player.tile()) if _player else (_target.global_position if _target else Vector2.ZERO)
	var start := Vector2i(floori(pos.x / TILE_SIZE), floori(pos.y / TILE_SIZE))
	_travel.start(biome, start, world_gen_params, world_seed, threaded_generation and _threads_available())


func is_finding_biome() -> bool:
	return _travel.is_finding()


## Stops a running "Go to" search; biome_travel_finished then reports it
## cancelled.
func cancel_biome_travel() -> void:
	_travel.cancel()


## Main thread, once the search is done: moves the camera there (chunks
## stream in around it) unless the world changed meanwhile.
func _finish_biome_travel() -> void:
	var outcome := _travel.finish(world_seed)
	if outcome["found"]:
		var tile: Vector2i = outcome["tile"]
		if _player:
			teleport_player((Vector2(tile) + Vector2(0.5, 0.5)) * TILE_SIZE)
		elif _target:
			_target.global_position = (Vector2(tile) + Vector2(0.5, 0.5)) * TILE_SIZE
	biome_travel_finished.emit(outcome["biome"], outcome["found"], outcome["cancelled"])


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_B:
		toggle_biome_overlay()
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F5 and not OS.has_feature("web"):
		reload_content()


## Quick keyboard shortcut: hop between Material and Base Biome. The dropdown
## (view_mode_dropdown.gd) covers the full view list via set_view_mode().
func toggle_biome_overlay() -> void:
	set_view_mode(ViewMode.MATERIAL if _view_mode == ViewMode.BASE_BIOME else ViewMode.BASE_BIOME)


func _is_label_view(mode: ViewMode) -> bool:
	return ViewModesScript.is_label_view(mode)


## Public entry point for the view-mode dropdown. Rebuilds every currently
## loaded chunk's content in place (swap Sprite2D.texture, replace its label
## overlay and markers) rather than adding a second layer - see plan doc §7
## for why heatmap views are render methods, not overlays. The rebuilds are
## queued nearest first like any chunk job; each chunk shows the old view
## until its own rebuild arrives.
func set_view_mode(mode: ViewMode) -> void:
	if mode == _view_mode:
		return
	# Generation reads _view_mode: wait out the chunk being generated.
	_ctx.mutex.lock()
	_view_mode = mode
	_ctx.mutex.unlock()
	_streamer.invalidate()
	view_changed.emit(mode)


## Without a target (target_path unset) the area around the origin stays
## loaded, as the initial load always did.
func _process(delta: float) -> void:
	var save_clock: bool = session.advance(delta)
	if session.woke_in_tent():
		_leave_tent()
	wind.advance(delta, clock.rate())
	wind.apply(sway_material, clock.minutes)
	wind.apply(shadow_material, clock.minutes)
	SunShadowScript.apply(shadow_material, clock.minutes)
	terrain_material.set_shader_parameter("water_phase", wind.phase)
	terrain_material.set_shader_parameter("ground_detail", is_time_tinted_view())
	terrain_material.set_shader_parameter("wave_dir", WindScript.direction_at(clock.minutes))
	var grass: Color = SeasonsScript.tint("grass", SeasonsScript.year_fraction(clock))
	terrain_material.set_shader_parameter("grass_tint", Vector4(grass.r, grass.g, grass.b, grass.a))
	_presenter.update_seasons()
	if save_clock:
		_save_gameplay_state()
	if _travel.poll():
		_finish_biome_travel()
	_streamer.process()


## Tests and benchmarks: finishes every chunk job for the current camera,
## view and LOD now and applies the results (ChunkStreamer.flush()).
## Afterwards the worker is idle until something changes, so generation
## functions are safe to call.
func flush_chunk_work() -> void:
	_streamer.flush()


## The debug overlay's counters (review W4, ChunkStreamer).
func take_perf_counters() -> Dictionary:
	return _streamer.take_perf_counters()


func has_pending_chunks() -> bool:
	return _streamer.has_pending()


## What the streamer loads around: the target's position (the origin
## without one, as the initial load always did), the zoom and the viewport.
func _camera_view() -> Array:
	return [_target.global_position if _target else Vector2.ZERO, _current_zoom(), get_viewport().get_visible_rect().size]


func _show_chunk(data: Dictionary) -> void:
	_presenter.show_chunk(data)


func _hide_chunk(chunk_coord: Vector2i) -> void:
	_presenter.unload_chunk(chunk_coord)


func _current_zoom() -> float:
	var cam := get_viewport().get_camera_2d()
	return cam.zoom.x if cam else 4.0


## Driven by CameraRig's "info_clicked" signal (a right click / long press) - samples the single clicked tile fresh (bypassing the topology
## cache is unnecessary here, it's one tile) and hands the full sample +
## classification to the inspector panel, plus the placed resource (if
## any) under the exact click point.
func _on_tile_clicked(world_pos: Vector2) -> void:
	var tile := Vector2i(floori(world_pos.x / TILE_SIZE), floori(world_pos.y / TILE_SIZE))
	_ctx.mutex.lock()  # the worker may be generating a chunk
	var sample := _ctx.world_gen.sample(tile.x, tile.y)
	var classified: Dictionary = BiomeClassifierScript.classify_full(sample)
	var deposits := {}
	var state = EnvironmentalStateScript.from_sample(sample)
	var potentials := _ctx.deposit_potentials(sample, tile.x, tile.y)
	for ore in potentials:
		deposits[String(ore.id).capitalize()] = Vector2(potentials[ore], ResourceManagerScript.get_exposure(state, ore))
	var farming: float = ResourceManagerScript.get_suitability(state, CONTENT.farmland, classified)
	var shade: float = ResourceManagerScript.get_shade(state, world_seed, tile.x, tile.y, classified)
	var resource := _picker.resource_at(world_pos / TILE_SIZE)
	var ground := _builder.surface_at(sample, tile.x, tile.y)
	var structure := _ctx.structures.site_at(tile)
	var debug_lines: Array = []
	if is_debug_view():
		debug_lines = debug_breakdown(tile.x, tile.y)
	_ctx.mutex.unlock()
	_inspector_panel.show_info(tile, sample, classified, resource, deposits, farming, shade, ground.display_name if ground != null else "", debug_lines, structure)


## Phase 15: the gameplay record (ResourceInstance) of a placed instance -
## the one place views, the inspector and later gameplay get an instance's
## quality, size, health and harvest state from, with the player's changes
## (Phase 16) applied. Built on demand (pure, so
## rebuilding gives the same record); null for an unknown resource id. Call
## with _ctx.mutex held or the worker idle, like other generation queries.
func get_resource_instance(inst: Dictionary):
	var definition: ResourceDefinition = _definitions_by_id().get(inst["id"])
	if definition == null:
		return null
	var record = ResourceInstanceScript.create(inst, definition, _builder.instance_quality(inst))
	session.changes.apply(record)
	return record


## Instance id -> ResourceDefinition for every guild member (and Oak
## Placement's single definition) - WorldContent.definitions_by_id().
func _definitions_by_id() -> Dictionary:
	return CONTENT.definitions_by_id()


## Phase 16: the instances of a placement list the player hasn't harvested.
func _unchanged(instances: Array) -> Array:
	return session.unchanged(instances)


## Phase 16: the file this seed's gameplay changes are saved to, or "" when
## they aren't saved (the default dir under a test harness, see changes_dir).
func changes_path() -> String:
	if changes_dir == "" or (changes_dir == DEFAULT_CHANGES_DIR and get_tree().get_script() != null):
		return ""
	return "%s/%d.json" % [changes_dir, world_seed]


## Phase 16: harvests the resource at `world_pos` - the resource under the
## click, as hover_target() picks it (only what is drawn, ignoring what's
## already harvested). See _harvest().
func _on_harvest_clicked(world_pos: Vector2):
	return _harvest(hover_target(world_pos / TILE_SIZE))


## Harvests the placed instance `inst` ({} = nothing): records it in the
## gameplay changes, saves them, and redraws that chunk's markers. A tap
## walks up to its target first (_on_map_tapped()) and harvests that same
## instance on arrival, whatever the view is by then (review C3); nothing
## happens if it was harvested meanwhile.
## Returns the harvested ResourceInstance, or null if there was none.
func _harvest(inst: Dictionary):
	if inst.is_empty() or session.is_harvested(inst):
		return null
	_ctx.mutex.lock()  # the worker may be generating a chunk
	var entity = get_resource_instance(inst)
	if entity != null:
		session.harvest(entity)
		_save_gameplay_state()
	_ctx.mutex.unlock()
	if entity != null:
		_presenter.redraw_markers(Vector2i((entity.world_position / CHUNK_SIZE).floor()))
		_spawn_harvest_effect(entity)
	return entity


## Polish: the pop-and-specks feedback at a harvested object's tile centre
## (where its sprite was drawn), in its sprite colour.
func _spawn_harvest_effect(entity) -> void:
	var definition: ResourceDefinition = _definitions_by_id().get(entity.resource_id)
	if definition == null:
		return
	var effect := HarvestEffectScript.new()
	var has_sprite := definition.sprite_tile.x >= 0
	var texture: Texture2D = ResourceMarkerChunkScript.sprite_texture(definition.sprite_tile) if has_sprite else null
	if has_sprite and definition.sprite_texture != null:
		texture = definition.sprite_texture
	var color: Color = _presenter.sprite_fill(definition) if has_sprite else definition.debug_color
	effect.setup(texture, color, definition.sprite_size * ResourceMarkerChunkScript.SPRITE_SIZE, entity.key, definition.sprite_texture != null)
	effect.position = (ResourceMarkerChunkScript.pivot({"position": entity.world_position}) * TILE_SIZE).round()
	effect.name = "HarvestEffect"
	resources_root.add_child(effect)


## Phase 18 (developer tooling): whether a view is one of the Debug views,
## which show _debug_resource's suitability / density / patch noise /
## placement and add its factor breakdown to the inspector.
func is_debug_view(mode: ViewMode = _view_mode) -> bool:
	return ViewModesScript.is_debug(mode)


## Every resource the Debug views can show: each stack member, in
## stack order.
func debug_resources() -> Array[ResourceDefinition]:
	var list: Array[ResourceDefinition] = []
	for guild in CONTENT.guilds:
		for member in guild.members:
			list.append(member)
	return list


func debug_resource() -> ResourceDefinition:
	return _debug_resource


## The guild the debug resource is placed with.
func debug_guild() -> ResourceGuild:
	return _builder.debug_guild()


## Picks the resource the Debug views show; rebuilds them if one is showing.
func set_debug_resource(definition: ResourceDefinition) -> void:
	if definition == _debug_resource:
		return
	_ctx.mutex.lock()
	_debug_resource = definition
	_ctx.mutex.unlock()
	if is_debug_view():
		_streamer.invalidate()
	debug_resource_changed.emit(definition)


## Phase 18: the inspector's breakdown of the debug resource at a tile - its
## suitability factor by factor (ResourceManager.explain_suitability()), then
## how the guild turns that into density. Call with _ctx.mutex held.
func debug_breakdown(wx: int, wy: int) -> Array[String]:
	var guild := debug_guild()
	var v := _builder.debug_values(wx, wy)
	var env := _ctx.tile_env(wx, wy)
	var lines: Array[String] = ["[b]%s[/b] (%s)" % [String(_debug_resource.id).capitalize(), String(guild.id).capitalize()]]
	lines.append_array(ResourceManagerScript.explain_suitability(env[0], _debug_resource, env[1])["lines"])
	if _debug_resource.vein_scale > 0.0:
		lines.append("member score (exposed deposit): %.3f" % v["score"])
	lines.append("guild cover (%s): %.2f" % [guild.cover_field if guild.cover_field != "" else "full", v["cover"]])
	lines.append("%s: %.2f" % ["stand membership" if guild.cover_sets_area else "patch modifier", v["patch"]])
	lines.append("best member score: %.2f   species share: %.2f" % [v["best"], v["share"]])
	lines.append("guild density: %.3f   %s density: %.3f" % [_ctx.guild_density(guild, wx, wy), _debug_resource.id, v["density"]])
	return lines


## This seed's saved changes and time (a new world: none, START_MINUTES).
func _load_gameplay_state() -> void:
	_leave_tent()
	var position: Variant = session.load_seed(changes_path(), world_seed)
	if _player:
		_player.teleport(position if position != null else _nearest_walkable(Vector2i.ZERO))


## Saves the changes and the current time for this seed (nothing under a
## test harness with the default dir - see changes_path()).
func _save_gameplay_state() -> void:
	session.save(_player.position if _player else null)


## Saves on quit, and whenever the game loses focus or is paused (a browser
## tab can close without a close request; review W6).
func _notification(what: int) -> void:
	if what in [NOTIFICATION_WM_CLOSE_REQUEST, NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_APPLICATION_PAUSED]:
		_save_gameplay_state()


## Views the day/night cycle tints (DayNight): the gameplay views only.
func is_time_tinted_view() -> bool:
	return ViewModesScript.is_tinted(_view_mode)


## Player (user request): a tap / left click (CameraRig "map_tapped") walks
## the player there along find_path() - around water; to the nearest
## reachable tile if the spot itself can't be reached. Tapping a resource
## walks up to it (within one tile) and harvests it on arrival
## (_on_harvest_clicked()), unless another tap redirects the player first.
## Tapping a camp tent likewise walks up to it and goes in to sleep
## (enter_tent()). A tap while asleep wakes the player first (and only
## wakes them, on the tent they're in).
## Returns the path.
func _on_map_tapped(world_pos: Vector2) -> Array[Vector2i]:
	if _player == null:
		_on_harvest_clicked(world_pos)
		return []
	var goal := Vector2i((world_pos / TILE_SIZE).floor())
	if session.tent_tile != null:
		var was_in: Vector2i = session.tent_tile
		clock.wake()
		_leave_tent()
		if goal == was_in:  # tapping the tent they're in just wakes them
			return []
	var tent := is_tent(goal)
	var inst := {} if tent else hover_target(world_pos / TILE_SIZE)
	var on_arrive := Callable()
	# Where the walk ends: the tapped point, or next to a tapped resource or
	# tent (its pivot, the base of its sprite).
	var object_at := Vector2.ZERO
	if tent:
		var tent_tile := goal
		on_arrive = func() -> void: enter_tent(tent_tile)
		object_at = (Vector2(goal) + Vector2(0.5, 1.0)) * TILE_SIZE
	elif not inst.is_empty():
		goal = Vector2i((inst["position"] as Vector2).floor())
		var target := inst
		on_arrive = func() -> void: _harvest(target)
		object_at = ResourceMarkerChunkScript.pivot(inst) * TILE_SIZE
	var to_object := tent or not inst.is_empty()
	_ctx.mutex.lock()
	var path := find_path(_player.tile(), goal, to_object)
	var end: Vector2i = path[-1] if not path.is_empty() else _player.tile()
	var points: Array[Vector2] = []
	for t in path:
		points.append((Vector2(t) + Vector2(0.5, 0.5)) * TILE_SIZE)
	if to_object:
		if maxi(absi(end.x - goal.x), absi(end.y - goal.y)) > 1:
			on_arrive = Callable()  # stopped short (unreachable): no harvest
		else:
			# Stand beside it, on the side the walk comes from.
			var from: Vector2 = points[-1] if not points.is_empty() else _player.position
			var side := from - object_at
			side = side.normalized() if side.length() > 0.5 else Vector2.DOWN
			var stand := object_at + side * STAND_OFF * TILE_SIZE
			if _ctx.is_walkable(Vector2i((stand / TILE_SIZE).floor())):
				_set_last(points, stand, end)
	elif end == goal:
		_set_last(points, world_pos, end)
	points = NavigationScript.smooth_path(_player.position, points, _ctx.is_walkable, TILE_SIZE)
	_ctx.mutex.unlock()
	_player.walk(points, on_arrive)
	return path


## How far (tiles) from a tapped resource's or tent's base the player stops.
const STAND_OFF := 0.6


## Makes `point` the walk's last point: it replaces the last tile centre,
## or is the only point when the walk stays on the start tile (`end`).
func _set_last(points: Array[Vector2], point: Vector2, end: Vector2i) -> void:
	if points.is_empty() or Vector2i((point / TILE_SIZE).floor()) != end:
		points.append(point)
	else:
		points[-1] = point


## Whether a camp tent stands on `tile` (a "tent" part of the site there).
func is_tent(tile: Vector2i) -> bool:
	return not _tent_site(tile).is_empty()


## The camp site whose tent stands on `tile`, or {}. Looked up under
## _ctx.mutex: site_at() may build the site (sampling the world) and the
## worker writes the same StructureSites cache (review C2).
func _tent_site(tile: Vector2i) -> Dictionary:
	_ctx.mutex.lock()
	var site := _ctx.structures.site_at(tile)
	_ctx.mutex.unlock()
	for part in site.get("parts", []):
		if part["tile"] == tile and part["kind"] == "tent":
			return site
	return {}


## How the World view draws the camp tent on `tile`: [texture, rect in
## world px, draw alpha 1 (rigid)] (a structure part, on its tile's bottom
## middle); [] if no tent stands there.
func tent_drawn(tile: Vector2i) -> Array:
	_ctx.mutex.lock()  # site_at() may build the site, sampling the world
	var site := _ctx.structures.site_at(tile)
	_ctx.mutex.unlock()
	for part in site.get("parts", []):
		if part["tile"] == tile and part["kind"] == "tent":
			return ResourceMarkerChunkScript.sprite_draw({"tile": part["sheet"], "size": 1.0}, (Vector2(tile) + Vector2(0.5, 1.0)) * TILE_SIZE) + [1.0]
	return []


## Sleeping in a tent (user request): the player goes inside the tent on
## `tile` (hidden), the tent bounces with Zs coming out (TentSleepEffect)
## and time speeds up until the next night start or dawn
## (GameClock.sleep()); _process() brings the player out when the clock
## wakes. Nothing happens if there's no tent there.
func enter_tent(tile: Vector2i) -> void:
	var site := _tent_site(tile) if _player != null else {}
	if site.is_empty():
		return
	_leave_tent()
	session.tent_tile = tile
	_player.visible = false
	var chunk := Vector2i((Vector2(tile) / CHUNK_SIZE).floor())
	_presenter.redraw_markers(chunk)
	var def: StructureDefinition = site["definition"]
	var tent_sheet := Vector2i.ZERO
	for part in def.parts:
		if part["kind"] == "tent":
			tent_sheet = part["tile"]
	_tent_effect = TentSleepEffectScript.new()
	_tent_effect.name = "TentSleep"
	# Above the marker chunks (re)added to Resources after it, and the
	# Overlay, so the Zs are never hidden behind neighbouring sprites.
	_tent_effect.z_index = 1
	_tent_effect.setup(ResourceMarkerChunkScript.sprite_texture(tent_sheet), def.kind_colors["tent"], ResourceMarkerChunkScript.SPRITE_SIZE)
	# Its tent stands on the tile's bottom edge, as the marker's does.
	_tent_effect.position = (Vector2(tile) + Vector2(0.5, 1.0)) * TILE_SIZE - Vector2(0, ResourceMarkerChunkScript.SPRITE_SIZE * 0.5)
	resources_root.add_child(_tent_effect)
	clock.sleep()


## Whether the player is asleep in a tent.
func is_in_tent() -> bool:
	return session.tent_tile != null


## The player comes out of the tent (shown again where they went in) and
## the tent's own marker returns. Leaves the clock alone.
func _leave_tent() -> void:
	if session.tent_tile == null:
		return
	var tile: Vector2i = session.tent_tile
	session.tent_tile = null
	if is_instance_valid(_tent_effect):
		_tent_effect.name = "TentSleepFading"  # frees itself once its Zs fade
		_tent_effect.wake()
	_tent_effect = null
	if _player:
		_player.visible = true
	_presenter.redraw_markers(Vector2i((Vector2(tile) / CHUNK_SIZE).floor()))


## Moves the player to the walkable tile nearest `world_pos` (its centre if
## the spot itself is water) and centres the camera on them.
func teleport_player(world_pos: Vector2) -> void:
	if _player == null:
		return
	clock.wake()
	_leave_tent()
	var tile := Vector2i((world_pos / TILE_SIZE).floor())
	_ctx.mutex.lock()
	var walkable := _ctx.is_walkable(tile)
	_ctx.mutex.unlock()
	_player.teleport(world_pos if walkable else _nearest_walkable(tile))
	if _target and _target.has_method("snap_to_player"):
		_target.snap_to_player()


## The walkable tile nearest `tile` (Navigation.nearest_walkable()), as a
## world position at its centre.
func _nearest_walkable(tile: Vector2i) -> Vector2:
	_ctx.mutex.lock()
	var found := NavigationScript.nearest_walkable(tile, _ctx.is_walkable_held)
	_ctx.mutex.unlock()
	return (Vector2(found) + Vector2(0.5, 0.5)) * TILE_SIZE


## A* from `from` to `to` over walkable tiles (Navigation.find_path()).
## Holds _ctx.mutex for the whole search (is_walkable() may sample).
func find_path(from: Vector2i, to: Vector2i, near: bool = false) -> Array[Vector2i]:
	_ctx.mutex.lock()
	var path := NavigationScript.find_path(from, to, _ctx.is_walkable_held, near)
	_ctx.mutex.unlock()
	return path


## Polish pass 2 (AmbientParticles): the environment at a tile for the
## particle rules - {} when generation holds the lock this instant (the
## caller just tries elsewhere later; the main thread never waits on it).
func ambient_env(tile: Vector2i) -> Dictionary:
	if not _ctx.mutex.try_lock():
		return {}
	var env := _ctx.tile_env(tile.x, tile.y)
	var state: EnvironmentalState = env[0]
	var shade: float = ResourceManagerScript.get_shade(state, world_seed, tile.x, tile.y, env[1])
	var result := {
		"hour": clock.hour_of_day(),
		"year": SeasonsScript.year_fraction(clock),
		"wind": WindScript.strength_at(clock.minutes),
		"wind_dir": WindScript.direction_at(clock.minutes),
		"temperature": state.temperature,
		"moisture": state.moisture,
		"vegetation": state.vegetation,
		"shade": shade,
		"water": state.water_body in ["ocean", "sea", "lake", "river"],
		"biome": String(env[1].get("base_biome", "")),
	}
	_ctx.mutex.unlock()
	return result

## Polish (HoverHighlight): the resource a left click at `point` (tile
## units) would harvest, or {} (ResourcePicker.hover_target()).
func hover_target(point: Vector2) -> Dictionary:
	return _picker.hover_target(point)


## Where a placed resource's sprite is drawn and clicked (ResourcePicker).
func sprite_point(inst: Dictionary) -> Vector2:
	return _picker.sprite_point(inst)


func sprite_drawn(inst: Dictionary) -> Array:
	return _picker.sprite_drawn(inst)


func sprite_image(texture: Texture2D) -> Image:
	return _picker.sprite_image(texture)
