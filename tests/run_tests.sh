#!/usr/bin/env bash
# Headless test runner for the resource-generation work.
#
#   tests/run_tests.sh              run the pass/fail suites
#   tests/run_tests.sh --by-biome   also print the per-biome placement breakdown
#   OUT_PNG=/tmp/p.png tests/run_tests.sh   also render the placement view
#
# Uses $GODOT if set, else downloads the same Godot the web-build CI uses
# into ~/.cache/godot (needed in cloud sessions, which have no Godot).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=4.7.2-stable
if [[ -z "${GODOT:-}" ]]; then
  GODOT="$HOME/.cache/godot/Godot_v${VERSION}_linux.x86_64"
  if [[ ! -x "$GODOT" ]]; then
    mkdir -p "$(dirname "$GODOT")"
    curl -sSL -o /tmp/godot.zip "https://github.com/godotengine/godot-builds/releases/download/${VERSION}/Godot_v${VERSION}_linux.x86_64.zip"
    unzip -qo /tmp/godot.zip -d "$(dirname "$GODOT")"
    rm /tmp/godot.zip
  fi
fi

# class_name lookups in --script runs need .godot/global_script_class_cache.cfg,
# which only the editor (re)builds - a short headless editor run does it.
"$GODOT" --headless --path . --editor --quit-after 30 >/dev/null 2>&1 || true

status=0
for t in tests/test_*.gd; do
  echo "== $t"
  out=$(timeout 900 "$GODOT" --headless --path . --script "res://$t" 2>&1) || status=1
  echo "$out" | grep -E "^(PASS|FAIL|INFO|RESULT)|SCRIPT ERROR|ERROR:" || true
  echo "$out" | grep -q "^RESULT" || { echo "no RESULT line - script crashed or hung"; status=1; }
done

if [[ "${1:-}" == "--by-biome" ]]; then
  echo "== tests/resource_by_biome.gd"
  timeout 900 "$GODOT" --headless --path . --script res://tests/resource_by_biome.gd 2>&1 | grep -E "^(WARN|  |')" || true
fi

exit $status
