extends SceneTree

## Writes the game's synthesized sound effects (lo-fi / chiptune style) to
## res://assets/sfx/ - deterministic (fixed seeds), so re-running it gives
## the same files. Tweak a recipe here and re-run:
##
##   $GODOT --headless --path . --script res://tools/generate_sfx.gd
##
## footstep.wav: a faint, light step - one short, soft brush of band-passed
## noise (most of it 400 Hz - 2 kHz: no boom below, little hiss above), smoothed
## so it isn't grainy, with a rounded envelope (no click, no tone). The game
## varies its pitch and volume per step (player.gd).

const RATE := 22050


func _init() -> void:
	_save("res://assets/sfx/footstep.wav", _footstep())
	quit()


func _footstep() -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var length := 0.06
	var n := int(length * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var smooth := 0.0
	var low := 0.0
	var high := 0.0
	for i in n:
		var t := float(i) / RATE
		# Smoothed noise (less grain), low-passed (~1.2 kHz), minus a slower
		# low-pass (~350 Hz): a light band, no depth.
		smooth += 0.4 * (rng.randf_range(-1.0, 1.0) - smooth)
		low += 0.32 * (smooth - low)
		high += 0.1 * (low - high)
		out[i] = (low - high) * _brush(t, 0.0, 0.055)
	# Normalize to a quiet peak.
	var peak := 0.0
	for v in out:
		peak = maxf(peak, absf(v))
	for i in n:
		out[i] = out[i] / peak * 0.3
	return out


## A rounded bump starting at `start` lasting `length` s (sine-squared: no
## sharp attack, fades out smoothly).
func _brush(t: float, start: float, length: float) -> float:
	var x := (t - start) / length
	if x <= 0.0 or x >= 1.0:
		return 0.0
	return pow(sin(PI * x), 2.0)


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
