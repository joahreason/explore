extends SceneTree

## Writes the game's synthesized sound effects (lo-fi / chiptune style) to
## res://assets/sfx/ - deterministic (fixed seeds), so re-running it gives
## the same files. Tweak a recipe here and re-run:
##
##   $GODOT --headless --path . --script res://tools/generate_sfx.gd
##
## footstep.wav: a faint, soft step - a low-passed noise scuff over a small
## thump that drops in pitch, lightly bit-crushed. The game varies its pitch
## and volume per step (player.gd).

const RATE := 22050


func _init() -> void:
	_save("res://assets/sfx/footstep.wav", _footstep())
	quit()


func _footstep() -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var length := 0.09
	var n := int(length * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var lp := 0.0
	var phase := 0.0
	for i in n:
		var t := float(i) / RATE
		var attack := minf(t / 0.003, 1.0)
		# Scuff: white noise through a one-pole low-pass (dull, not hissy).
		lp += 0.18 * (rng.randf_range(-1.0, 1.0) - lp)
		var scuff := lp * exp(-t / 0.016)
		# Thump: a sine sliding 110 -> 70 Hz, a touch longer.
		var freq := lerpf(110.0, 70.0, minf(t / length, 1.0))
		phase += TAU * freq / RATE
		var thump := sin(phase) * exp(-t / 0.022)
		out[i] = attack * (1.6 * scuff + 0.45 * thump)
	# Normalize to a quiet peak, then crush to 64 levels (lo-fi grit).
	var peak := 0.0
	for v in out:
		peak = maxf(peak, absf(v))
	for i in n:
		out[i] = roundf(out[i] / peak * 0.35 * 32.0) / 32.0
	return out


func _save(path: String, samples: PackedFloat32Array) -> void:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	var peak := 0.0
	var sum := 0.0
	for i in samples.size():
		var v := clampf(samples[i], -1.0, 1.0)
		data.encode_s16(i * 2, int(roundf(v * 32767.0)))
		peak = maxf(peak, absf(v))
		sum += v * v
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = data
	wav.save_to_wav(ProjectSettings.globalize_path(path))
	print("wrote %s: %d ms, peak %.1f dBFS, rms %.1f dBFS" % [path, samples.size() * 1000 / RATE, linear_to_db(peak), linear_to_db(sqrt(sum / samples.size()))])
