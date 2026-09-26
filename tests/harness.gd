extends SceneTree

## Shared base for the test suites (review T6): `extends "res://tests/harness.gd"`,
## then check() each expectation and end with finish(). tests/run_tests.sh
## reads the PASS / FAIL lines, the RESULT line and the exit code.

var _passes := 0
var _fails := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		_passes += 1
		print("PASS ", msg)
	else:
		_fails += 1
		print("FAIL ", msg)


## Prints the RESULT line and quits, non-zero if any check failed.
func finish() -> void:
	print("RESULT %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)
