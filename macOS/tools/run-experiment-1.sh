#!/bin/bash
# Experiment 1, measured rather than looked at.
#
# The question: does macOS colour-manage a CAMetalLayer whose colorspace is
# nil? SDL leaves it nil for an ordinary SDR window, so the answer decides
# whether the Patch Companion's patches reach the panel as the code values it
# asked for.
#
# Method: assign a deliberately permuted display profile (red and green
# colorants swapped), then show the same nominal red twice at the same spot -
# once through our nil-colorspace Metal layer, once through an sRGB-tagged
# control layer macOS definitely manages - and compare measured chromaticity.
# Red and green primaries are half the xy diagram apart, so the verdict is
# arithmetic rather than a judgement about whether a red looks wrong enough.
#
#   ./run-experiment-1.sh --check              preflight only, changes nothing
#   ./run-experiment-1.sh <display-id> <index>
#   ./run-experiment-1.sh 0x00000002 1
#
# Both values come from `./pgen-colorsync-probe list`. The id is the 0x... one;
# the index is its position in that list, counting from 0.
#
# Nothing touches the display until the meter has been proven to work, and the
# display's own profile is restored on exit and on Ctrl-C.

set -u
cd "$(dirname "$0")" || exit 1

DWELL=14
PERMUTED=/tmp/pgen-permuted.icc

# ---------------------------------------------------------------- preflight

# Ask ArgyllCMS what instruments it can see. Its -? output lists the ports it
# would offer for -c; a machine with no meter shows only serial devices, so
# anything that is not a /dev/ path is a real instrument.
instrument_list() {
    spotread -? 2>&1 | awk "/-c listno/,/^ *-t /" \
        | grep -E "^ +[0-9]+ = " | sed -E "s/^ +([0-9]+) = '(.*)'.*/\1|\2/"
}

check_meter() {
    if ! command -v spotread >/dev/null 2>&1; then
        echo "spotread not found. Install it with: brew install argyll-cms" >&2
        return 1
    fi
    local list found
    list=$(instrument_list)
    found=$(echo "$list" | grep -v "|/dev/" | head -1)
    echo "instruments ArgyllCMS reports:"
    if [ -z "$list" ]; then
        echo "  (none at all)"
    else
        echo "$list" | sed 's/^/  /' | sed 's/|/  =  /'
    fi
    if [ -z "$found" ]; then
        cat >&2 <<'MSG'

No colorimeter is visible to ArgyllCMS - only serial ports are listed.

Things worth checking, roughly in order:
  - is the meter plugged directly into the Mac rather than through a hub?
  - does another application have it open? Close any calibration software,
    including a vendor utility sitting in the menu bar.
  - does `spotread -e -x -O` on its own see it?
  - some meters need their diffuser closed for emissive display measurement.

Nothing has been changed on your display.
MSG
        return 1
    fi
    METER_PORT=$(echo "$found" | cut -d'|' -f1)
    echo "using instrument $METER_PORT"
    return 0
}

# One reading. stderr is kept, because hiding it is what made the first
# failure of this script impossible to diagnose.
read_meter() {
    local out
    out=$(spotread -e -x -O -c "$METER_PORT" 2>&1)
    LAST_METER_OUTPUT=$out
    echo "$out" | grep -iE "Yxy:" | tail -1 \
        | sed -E 's/.*Yxy: *([0-9.]+) +([0-9.]+) +([0-9.]+).*/\1 \2 \3/'
}

METER_PORT=""
LAST_METER_OUTPUT=""

if [ $# -ge 1 ] && [ "$1" = "--check" ]; then
    check_meter || exit 1
    echo
    echo "taking one test reading of whatever is on screen now..."
    result=$(read_meter)
    if [ -n "$result" ]; then
        echo "  Yxy: $result"
        echo "the meter works. Re-run with a display id and index to do the experiment."
    else
        echo "  no reading. spotread said:" >&2
        echo "$LAST_METER_OUTPUT" | sed 's/^/    /' >&2
    fi
    exit 0
fi

# ---------------------------------------------------------------- arguments

if [ $# -lt 2 ]; then
    echo "usage: $0 <display-id> <display-index>   e.g. $0 0x00000002 1" >&2
    echo "       $0 --check                        test the meter only" >&2
    echo "run ./pgen-colorsync-probe list for both values" >&2
    exit 2
fi

DISPLAY_ID=$1
DISPLAY_INDEX=$2

# Validate the index here rather than letting the probe reject it into a
# silenced stderr, which is how "N" got all the way to a meaningless run.
case "$DISPLAY_INDEX" in
    ''|*[!0-9]*)
        echo "'$DISPLAY_INDEX' is not a display index." >&2
        echo "It is the position in ./pgen-colorsync-probe list, counting from 0." >&2
        exit 2 ;;
esac

echo "checking the meter before touching anything..."
check_meter || exit 1
echo

echo "reading the current profile for display $DISPLAY_ID..."
# Profile paths contain spaces ("Color LCD-...icc"), so take the whole line
# after the "profile" key and strip the trailing [factory]/[custom] marker.
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
    exit 1
fi
echo "  $ORIGINAL"

# Check the index is in range before a profile is swapped. --list would exit
# zero whatever index it was given, so count the displays instead.
DISPLAY_COUNT=$(./pgen-colorsync-probe list 2>/dev/null \
                | sed -n 's/^\([0-9][0-9]*\) display(s)/\1/p' | head -1)
if [ -n "$DISPLAY_COUNT" ] && [ "$DISPLAY_INDEX" -ge "$DISPLAY_COUNT" ]; then
    echo "display index $DISPLAY_INDEX is out of range: there are $DISPLAY_COUNT" >&2
    echo "displays, so the index must be 0 to $((DISPLAY_COUNT - 1))." >&2
    exit 2
fi

# ---------------------------------------------------------------- restore

ASSIGNED=""
cleanup() {
    pkill -f pgen-macos-hdr-probe 2>/dev/null
    if [ -n "$ASSIGNED" ]; then
        echo
        echo "restoring the display's own profile..."
        ./pgen-colorsync-probe restore "$DISPLAY_ID" >/dev/null 2>&1
        ASSIGNED=""
    fi
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------- run

echo "building the permuted profile (red and green colorants swapped)..."
python3 make-permuted-profile.py build "$ORIGINAL" "$PERMUTED" >/dev/null || exit 1

echo "assigning it to $DISPLAY_ID..."
./pgen-colorsync-probe assign "$DISPLAY_ID" "$PERMUTED" >/dev/null || {
    echo "assignment failed" >&2; exit 1; }
ASSIGNED=1
sleep 2

measure() {
    local layout=$1 label=$2 result probe_err
    probe_err=$(mktemp)
    ./pgen-macos-hdr-probe --display "$DISPLAY_INDEX" "$layout" 255,0,0 \
        --dwell "$DWELL" >/dev/null 2>"$probe_err" &
    local probe=$!
    sleep 3
    if ! kill -0 $probe 2>/dev/null; then
        echo "  $label: the patch window exited early. Probe said:" >&2
        sed 's/^/    /' "$probe_err" >&2
        rm -f "$probe_err"
        echo ""
        return
    fi
    result=$(read_meter)
    wait $probe 2>/dev/null
    rm -f "$probe_err"
    if [ -z "$result" ]; then
        echo "  $label: no reading. spotread said:" >&2
        echo "$LAST_METER_OUTPUT" | sed 's/^/    /' >&2
        echo ""
        return
    fi
    echo "$result"
}

echo
echo "measuring OUR layer (colorspace nil)  - keep the meter still..."
OURS=$(measure --sdr-ours ours)
echo "  ${OURS:-(none)}"

echo "measuring the sRGB CONTROL layer..."
CONTROL=$(measure --sdr-control control)
echo "  ${CONTROL:-(none)}"

cleanup

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
    print("The reason is printed above, immediately after whichever step failed.")
    raise SystemExit(1)

_, ox, oy = ours
_, cx, cy = control
distance = ((ox - cx) ** 2 + (oy - cy) ** 2) ** 0.5

print(f"  our layer      x {ox:.4f}  y {oy:.4f}")
print(f"  sRGB control   x {cx:.4f}  y {cy:.4f}")
print(f"  separation     {distance:.4f} in xy")
print()

# A red primary and a green primary are roughly 0.4-0.6 apart in xy; two
# readings of the same colour at the same spot agree to a few thousandths.
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
    print("  this run proves nothing.")
else:
    print("VERDICT: FAIL")
    print("  Both layers measured away from red, so our layer is being colour-")
    print("  managed too. The Companion's SDR premise is wrong and the")
    print("  correction-mode design has to change.")
PY
