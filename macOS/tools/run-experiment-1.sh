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
#   ./run-experiment-1.sh --check          preflight only, changes nothing
#   ./run-experiment-1.sh --aim <id>       show red and read, to place the meter
#   ./run-experiment-1.sh --vcgt <id>      separate the ICC and GPU-LUT stages
#   ./run-experiment-1.sh <display-id>
#   ./run-experiment-1.sh 0x00000002
#
# The id is the 0x... value from `./pgen-colorsync-probe list`. There is no
# index: NSScreen.screens and CGGetOnlineDisplayList are ordered independently,
# so an index taken from one and applied to the other can silently target the
# wrong panel.
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
DISPLAY_ID=""

measure() {
    local layout=$1 label=$2 result probe_err
    probe_err=$(mktemp)
    ./pgen-macos-hdr-probe --display-id "$DISPLAY_ID" "$layout" 255,0,0 \
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

# measure() always shows red; this takes any fill, for the aiming test.
measure_fill() {
    local fill=$1 label=$2 result probe_err
    probe_err=$(mktemp)
    ./pgen-macos-hdr-probe --display-id "$DISPLAY_ID" --sdr-ours "$fill" \
        --dwell "$DWELL" >"$probe_err" 2>&1 &
    local probe=$!
    sleep 3
    if ! kill -0 $probe 2>/dev/null; then
        echo "  $label: the patch window exited early:" >&2
        sed 's/^/    /' "$probe_err" >&2
        rm -f "$probe_err"; echo ""; return
    fi
    result=$(read_meter)
    kill $probe 2>/dev/null; wait $probe 2>/dev/null
    grep -E "^window |^metal layer|nil - nothing|WARNING: the Metal" "$probe_err" \
        | sed 's/^/    /' >&2
    rm -f "$probe_err"
    if [ -z "$result" ]; then
        echo "  $label: no reading. spotread said:" >&2
        echo "$LAST_METER_OUTPUT" | sed 's/^/    /' >&2
        echo ""; return
    fi
    echo "$result"
}


# Position the meter, and prove it is looking at the display at all.
#
# The test is differential: measure the same spot with the display filled black
# and then filled red. If the two readings match, the meter is not seeing this
# screen - it is reading ambient light, or facing the wrong way, or the patch is
# not being displayed. That distinction is invisible to any single reading.
if [ $# -ge 2 ] && [ "$1" = "--aim" ]; then
    check_meter || exit 1
    DISPLAY_ID=$2
    echo
    echo "A full-screen patch will appear on $DISPLAY_ID."
    echo "Put the meter flat against that screen, roughly centred, lens open."
    echo "On an i1 Display Pro the diffuser arm must be rotated AWAY from the"
    echo "lens - with it closed the meter reads the room, not the display."
    echo
    sleep 2

    echo "showing BLACK..."
    BLACK=$(measure_fill 0,0,0 black)
    echo "  ${BLACK:-(none)}"
    echo "showing RED..."
    RED=$(measure_fill 255,0,0 red)
    echo "  ${RED:-(none)}"

    python3 - "${BLACK:-}" "${RED:-}" <<'AIMPY'
import sys
def parse(t):
    p = t.split()
    return [float(v) for v in p] if len(p) == 3 else None
black, red = parse(sys.argv[1]), parse(sys.argv[2])
print()
if not black or not red:
    print("  no readings - the reason is printed above.")
    raise SystemExit(1)
bY, bx, by = black
rY, rx, ry = red
print(f"  black   Y {bY:8.3f}  x {bx:.4f}  y {by:.4f}")
print(f"  red     Y {rY:8.3f}  x {rx:.4f}  y {ry:.4f}")
ratio = rY / bY if bY > 0.001 else 999.0
print(f"  red/black luminance ratio  {ratio:.2f}")
print()
if ratio < 1.3:
    print("  NOT SEEING THE DISPLAY.")
    print("  Black and red measured the same, so the meter is not reading this")
    print("  screen. Check, in order:")
    print("    - the i1's diffuser arm is rotated away from the lens")
    print("    - the meter is flat against the VE228, not the built-in display")
    print("    - a full-screen patch actually appeared on that display")
elif rx > 0.45:
    print("  ON THE RED PATCH. Ready - run the experiment.")
else:
    print(f"  Seeing the display (it responded), but red measured x {rx:.3f}")
    print("  rather than about 0.64. Something is already transforming it.")
AIMPY
    exit 0
fi

# Experiment 1b: change one thing and nothing else.
#
# Experiment 1 showed our layer is not colour-managed the way the control is -
# the control went fully to green, ours barely moved. But ours did move, and
# two explanations for that have now been ruled out by measurement: it is not
# the display profile reaching an unmanaged layer (impossible), and it is not
# vcgt (holding vcgt constant did not stop it).
#
# The remaining suspect is everything else those rebuilt profiles dropped -
# Apple's private aarg/aabg/aagg parametric gamma tags in particular, which may
# feed the GPU transfer table the way vcgt does. Rebuilding the profile at all
# was the confound.
#
# So this uses --minimal: the source profile with exactly two bytes changed,
# the rXYZ and gXYZ tag signatures. Same tags, same offsets, same payloads,
# same length. If our layer does not move under that, the ICC colorants
# demonstrably do not reach it and every earlier shift was the GPU path.
if [ $# -ge 2 ] && [ "$1" = "--vcgt" ]; then
    check_meter || exit 1
    DISPLAY_ID=$2

    ORIGINAL=$(./pgen-colorsync-probe list 2>/dev/null | awk -v id="$DISPLAY_ID" '
        $1=="display" && $2==id {found=1; next}
        found && $1=="profile" {
            line=$0
            sub(/^[[:space:]]*profile[[:space:]]+/, "", line)
            sub(/[[:space:]]+\[[a-z]+\][[:space:]]*$/, "", line)
            print line; exit }')
    [ -f "$ORIGINAL" ] || { echo "no profile for $DISPLAY_ID" >&2; exit 1; }

    ASSIGNED=""
    cleanup_vcgt() {
        pkill -f pgen-macos-hdr-probe 2>/dev/null
        [ -n "$ASSIGNED" ] && ./pgen-colorsync-probe restore "$DISPLAY_ID" >/dev/null 2>&1
        ASSIGNED=""
    }
    trap cleanup_vcgt EXIT INT TERM

    echo
    echo "Four measurements, plus a drift check. Keep the meter still throughout."
    echo
    echo "with the display's OWN profile:"
    RED_BEFORE=$(measure_fill 255,0,0 red-before)
    echo "  red    ${RED_BEFORE:-(none)}"
    WHITE_BEFORE=$(measure_fill 255,255,255 white-before)
    echo "  white  ${WHITE_BEFORE:-(none)}"

    echo "building a profile that differs by exactly two bytes..."
    python3 make-permuted-profile.py build "$ORIGINAL" /tmp/pgen-permuted-vcgt.icc \
        --minimal || exit 1

    # Verify what was actually built rather than trusting the right code ran.
    # A stale copy silently produced a full rebuild once, and the run looked
    # normal while comparing profiles that differed in far more than colorants.
    DIFFERING=$(cmp -l "$ORIGINAL" /tmp/pgen-permuted-vcgt.icc 2>/dev/null | wc -l | tr -d " ")
    if [ "${DIFFERING:-0}" != "2" ]; then
        echo >&2
        echo "  ABORTING: that profile differs in ${DIFFERING:-many} bytes, not 2." >&2
        echo "  The minimal builder did not run. Nothing has been assigned." >&2
        exit 1
    fi
    echo "  verified: exactly 2 bytes differ"

    ./pgen-colorsync-probe assign "$DISPLAY_ID" /tmp/pgen-permuted-vcgt.icc >/dev/null \
        || { echo "assignment failed" >&2; exit 1; }
    ASSIGNED=1
    sleep 2

    echo "with the colorant tags swapped:"
    RED_AFTER=$(measure_fill 255,0,0 red-after)
    echo "  red    ${RED_AFTER:-(none)}"
    WHITE_AFTER=$(measure_fill 255,255,255 white-after)
    echo "  white  ${WHITE_AFTER:-(none)}"

    cleanup_vcgt
    sleep 2
    echo "back on the display's own profile, re-measuring red (drift check):"
    RED_AGAIN=$(measure_fill 255,0,0 red-again)
    echo "  red    ${RED_AGAIN:-(none)}"

    python3 - "${RED_BEFORE:-}" "${WHITE_BEFORE:-}" "${RED_AFTER:-}" \
             "${WHITE_AFTER:-}" "${RED_AGAIN:-}" <<'VPY'
import sys
def parse(t):
    p = t.split()
    return [float(v) for v in p] if len(p) == 3 else None
rb, wb, ra, wa, rg = (parse(a) for a in sys.argv[1:6])
print()
if not all([rb, wb, ra, wa, rg]):
    print("  incomplete - reasons are above.")
    raise SystemExit(1)
def d(a, b):
    return ((a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2) ** 0.5
red_delta, white_delta, drift = d(rb, ra), d(wb, wa), d(rb, rg)
print(f"  red    own {rb[1]:.4f},{rb[2]:.4f}  Y {rb[0]:6.2f}   "
      f"swapped {ra[1]:.4f},{ra[2]:.4f}  Y {ra[0]:6.2f}   delta {red_delta:.4f}")
print(f"  white  own {wb[1]:.4f},{wb[2]:.4f}  Y {wb[0]:6.2f}   "
      f"swapped {wa[1]:.4f},{wa[2]:.4f}  Y {wa[0]:6.2f}   delta {white_delta:.4f}")
print(f"  drift  red re-measured on the own profile: delta {drift:.4f}")
print()
if drift > 0.01:
    print("  UNSTABLE. Red did not return to its starting value after the")
    print("  profile was restored, so something is drifting - the panel warming,")
    print("  the meter settling, or the restore not taking. The other numbers")
    print("  cannot be trusted until this is stable.")
elif red_delta < 0.01 and white_delta < 0.01:
    print("  CONFIRMED. Neither red nor white moved. The display profile does")
    print("  not reach our layer at all - the SDR premise holds completely.")
elif red_delta > 0.01 and white_delta < 0.01:
    print("  PROFILE TRANSFORM REACHES OUR LAYER.")
    print("  Red moved while white did not, which is exactly the signature of a")
    print("  colorant swap: a neutral sums the same three colorants either way,")
    print("  so only non-neutrals change. Something derived from the display")
    print("  profile is being applied to our layer after CoreAnimation declines")
    print("  to colour-manage it.")
    print("  This does not break the port, but it changes what 'system' mode")
    print("  means on macOS and needs to be described accurately.")
else:
    print("  NOT THE COLORANT SWAP. White moved too, and a neutral is invariant")
    print("  under a red/green swap, so whatever is changing is not that.")
    print("  Suspect a side effect of assigning any profile at all - a LUT")
    print("  reload or a recalculated transform.")
VPY
    exit 0
fi

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

if [ $# -lt 1 ]; then
    echo "usage: $0 <display-id>      e.g. $0 0x00000002" >&2
    echo "       $0 --check           test the meter only" >&2
    echo "run ./pgen-colorsync-probe list for the id" >&2
    exit 2
fi

DISPLAY_ID=$1

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

# Aiming check, with the display's own profile still in place. Our layer is
# unmanaged, so a red fill must measure as red. If it does not, the meter is
# not looking at the patch - wrong display, wrong spot, or the window never
# came up - and no amount of profile swapping will fix that.
echo "checking the meter is actually on the patch..."
AIM=$(measure --sdr-ours aim)
echo "  ${AIM:-(none)}"
python3 - "${AIM:-}" <<'AIMPY' || exit 1
import sys
parts = sys.argv[1].split() if len(sys.argv) > 1 else []
if len(parts) != 3:
    print("\n  no reading, so there is nothing to aim. Reason is above.")
    raise SystemExit(1)
Y, x, y = (float(v) for v in parts)
# Distance from a rough D65 white point. A saturated primary is far from it;
# a desktop, a white window or a dark room is not.
saturation = ((x - 0.313) ** 2 + (y - 0.329) ** 2) ** 0.5
print(f"  Y {Y:.1f}  x {x:.4f}  y {y:.4f}   distance from white {saturation:.3f}")
if saturation < 0.15:
    print("""
  STOP - the meter is not seeing the red patch.

  That reading is close to neutral, which is what a desktop or a white window
  measures. A red patch reads around x 0.64, y 0.33.

  Check, in order:
    - is the meter physically on the display you named?
    - did a full-screen red window appear on that display?
    - is anything covering the meter, or is it reading ambient light?

  Nothing has been changed on your display.""")
    raise SystemExit(1)
if x < 0.45:
    print(f"""
  STOP - the patch measured saturated but not red (x {x:.3f}).

  With the display's own profile still assigned, our unmanaged layer should
  reproduce red directly. Something else is already transforming it.

  Nothing has been changed on your display.""")
    raise SystemExit(1)
print("  good - that is red. Proceeding.")
AIMPY
echo

echo "building the permuted profile (red and green colorants swapped)..."
python3 make-permuted-profile.py build "$ORIGINAL" "$PERMUTED" >/dev/null || exit 1

echo "assigning it to $DISPLAY_ID..."
./pgen-colorsync-probe assign "$DISPLAY_ID" "$PERMUTED" >/dev/null || {
    echo "assignment failed" >&2; exit 1; }
ASSIGNED=1
sleep 2


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

oY, ox, oy = ours
cY, cx, cy = control
distance = ((ox - cx) ** 2 + (oy - cy) ** 2) ** 0.5
# How far each reading sits from neutral. Two readings can agree simply because
# neither of them is the patch, and that is not a FAIL - it is no result.
ours_saturation = ((ox - 0.313) ** 2 + (oy - 0.329) ** 2) ** 0.5
control_saturation = ((cx - 0.313) ** 2 + (cy - 0.329) ** 2) ** 0.5

print(f"  our layer      x {ox:.4f}  y {oy:.4f}")
print(f"  sRGB control   x {cx:.4f}  y {cy:.4f}")
print(f"  separation     {distance:.4f} in xy")
print()

# A red primary and a green primary are roughly 0.4-0.6 apart in xy; two
# readings of the same colour at the same spot agree to a few thousandths.
# 0.05 sits far outside meter noise and far inside the red/green gap.
if ours_saturation < 0.15 and control_saturation < 0.15:
    print("VERDICT: INVALID - not a FAIL")
    print("  Both readings are close to neutral, so the meter was measuring")
    print("  something that is not the patch - a desktop, a white window, or")
    print("  ambient light. Note that swapping the red and green colorants is")
    print("  invisible on neutrals, because a neutral sums all three colorants")
    print("  either way, so two identical near-white readings are exactly what")
    print("  measuring the wrong thing looks like.")
elif distance > 0.05:
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
