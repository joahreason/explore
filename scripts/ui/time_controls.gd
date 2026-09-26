extends HBoxContainer

## Rewind / play-pause / fast-forward buttons for the world's in-game time
## (ChunkManager.clock, GameClock): each press of << or >> steps through
## GameClock.SPEEDS (x4, x16, x64, then back to x4); the middle button pauses
## and resumes, or returns to normal speed from rewind / fast-forward. Sits
## just above the clock label; the buttons never take keyboard focus.

@onready var _world := get_node("../..")
@onready var _rewind: Button = $Rewind
@onready var _play: Button = $PlayPause
@onready var _forward: Button = $FastForward


func _ready() -> void:
	for button in [_rewind, _play, _forward]:
		button.focus_mode = Control.FOCUS_NONE
	_rewind.pressed.connect(func(): _world.clock.rewind())
	_play.pressed.connect(func(): _world.clock.play_pause())
	_forward.pressed.connect(func(): _world.clock.fast_forward())


## The middle button shows what it will do: "||" pauses while time runs at
## normal speed, ">" plays (from paused, rewind or fast-forward).
func _process(_delta: float) -> void:
	var clock = _world.clock
	_play.text = "||" if not clock.paused and clock.direction == 0 else ">"
	_rewind.button_pressed = clock.direction < 0 and not clock.paused
	_forward.button_pressed = clock.direction > 0 and not clock.paused
