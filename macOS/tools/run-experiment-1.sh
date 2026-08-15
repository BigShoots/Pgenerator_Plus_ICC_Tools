#!/bin/bash
# Experiment 1, measured rather than looked at.
#
# The question: does macOS colour-manage a CAMetalLayer whose colorspace is
# nil? SDL leaves it nil for an ordinary SDR window, so the answer decides
# whether the Patch Companion's patches reach the panel as the code values it
# asked for.
#
# Judging that by eye needs someone to decide whether a red looks "wrong
# enough", and it cannot distinguish a real pass from a profile that never took.
# With a meter on the glass, both problems go away: assign a deliberately
# permuted profile, show the same nominal red through our layer and through an
# sRGB-tagged control layer, and compare the measured chromaticity. Red and
# green primaries are nowhere near each other in xy, so the verdict is
# arithmetic.
#
#   ./run-experiment-1.sh <display-id> <display-index>
#   ./run-experiment-1.sh 0x00000002 1
#
# Both come from `./pgen-colorsync-probe list`. Put the meter on the display
# you name, roughly centred, before starting.
#
# The display's own profile is restored at the end, including on Ctrl-C.

set -u
cd "$(dirname "$0")" || exit 1

if [ $# -lt 2 ]; then
    echo "usage: $0 <display-id> <display-index>   e.g. $0 0x00000002 1" >&2
    echo "run ./pgen-colorsync-probe list for both values" >&2
    exit 2
fi

DISPLAY_ID=$1
DISPLAY_INDEX=$2
DWELL=14           # long enough for spotread to settle and read
PERMUTED=/tmp/pgen-permuted.icc

command -v spotread >/dev/null 2>&1 || {
    echo "spotread not found. brew install argyll-cms" >&2; exit 1; }

# ---------------------------------------------------------------- restore

ORIGINAL=""
restore() {
    [ -n "$ORIGINAL" ] || return 0
    echo
    echo "restoring the display's own profile..."
    ./pgen-colorsync-probe restore "$DISPLAY_ID" >/dev/null 2>&1
    ORIGINAL=""
}
cleanup() {
    pkill -f pgen-macos-hdr-probe 2>/dev/null
    restore
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------- setup

echo "reading the current profile for display $DISPLAY_ID..."
# Profile paths contain spaces ("Color LCD-...icc"), so take the whole line
# after the "profile" key and strip the trailing [factory]/[custom] marker,
# rather than splitting on whitespace.
ORIGINAL=$(./pgen-colorsync-probe list 2>/dev/null | awk -v id="$DISPLAY_ID" '
    $1=="display" && $2==id {found=1; next}
    found && $1=="profile" {
        line=$0
        sub(/^[[:space:]]*profile[[:space:]]+/, "", line)
        sub(/[[:space:]]+\[[a-z]+\][[:space:]]*$/, "", line)
        print line
        exit
    }')

if [ -z "$ORIGINAL" ] || [ ! -f "$ORIGINAL" ]; then
    echo "could not read a profile file for $DISPLAY_ID." >&2
    echo "run ./pgen-colorsync-probe list and check the id." >&2
    ORIGINAL=""
    exit 1
fi
echo "  $ORIGINAL"

echo "building the permuted profile (red and green colorants swapped)..."
python3 make-permuted-profile.py build "$ORIGINAL" "$PERMUTED" >/dev/null || exit 1

echo "assigning it to $DISPLAY_ID..."
./pgen-colorsync-probe assign "$DISPLAY_ID" "$PERMUTED" >/dev/null || {
    echo "assignment failed" >&2; exit 1; }
sleep 2

# ---------------------------------------------------------------- measure

# One reading, emissive, Yxy, no auto-calibration, while the patch is up.
measure() {
    local layout=$1 label=$2 out
    ./pgen-macos-hdr-probe --display "$DISPLAY_INDEX" "$layout" 255,0,0 \
        --dwell "$DWELL" >/dev/null 2>&1 &
    local probe=$!
    sleep 3
    out=$(spotread -e -x -O -N 2>/dev/null | grep -i "Yxy:" | tail -1)
    wait $probe 2>/dev/null
    if [ -z "$out" ]; then
        echo "  $label: no reading from the meter" >&2
        echo ""
        return
    fi
    echo "$out" | sed -E 's/.*Yxy: *([0-9.]+) +([0-9.]+) +([0-9.]+).*/\1 \2 \3/'
}

echo
echo "measuring OUR layer (colorspace nil)  - keep the meter still..."
OURS=$(measure --sdr-ours ours)
echo "  $OURS"

echo "measuring the sRGB CONTROL layer..."
CONTROL=$(measure --sdr-control control)
echo "  $CONTROL"

restore

# ---------------------------------------------------------------- verdict

python3 - "$OURS" "$CONTROL" <<'PY'
import sys

def parse(text):
    parts = text.split()
    if len(parts) != 3:
        return None
    try:
        return [float(v) for v in parts]
    except ValueError:
        return None

ours, control = parse(sys.argv[1]), parse(sys.argv[2])
print()
if not ours or not control:
    print("VERDICT: no result - the meter did not return two readings.")
    print("Check it is plugged in, seated on the glass, and that spotread works.")
    raise SystemExit(1)

_, ox, oy = ours
_, cx, cy = control
distance = ((ox - cx) ** 2 + (oy - cy) ** 2) ** 0.5

print(f"  our layer      x {ox:.4f}  y {oy:.4f}")
print(f"  sRGB control   x {cx:.4f}  y {cy:.4f}")
print(f"  separation     {distance:.4f} in xy")
print()

# A red primary and a green primary are roughly 0.4-0.6 apart in xy; two
# readings of the same colour on the same spot agree to a few thousandths.
# 0.05 sits far outside meter noise and far inside the red/green gap.
if distance > 0.05:
    print("VERDICT: PASS")
    print("  The two layers measure as different colours, so macOS converted the")
    print("  control and left our layer alone. Patches reach the panel as the")
    print("  code values we ask for, and refusing the clut/matrix correction")
    print("  modes is correct.")
elif ox > 0.45:
    print("VERDICT: INVALID - not a pass")
    print("  Both layers measured near the red primary, which means the permuted")
    print("  profile was not actually applied. Nothing was colour-managed, so")
    print("  this run proves nothing. Check the display id and that the desktop")
    print("  visibly changed while it was assigned.")
else:
    print("VERDICT: FAIL")
    print("  Both layers measured away from red, so our layer is being colour-")
    print("  managed too. The Companion's SDR premise is wrong and the")
    print("  correction-mode design has to change.")
PY
