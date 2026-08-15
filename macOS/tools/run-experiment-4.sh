#!/bin/bash
# Experiment 4 - characterise the transform that reaches our layer.
#
# Spike A established two stages. Our layer escapes CoreAnimation's colour
# matching, which is the large effect: under a permuted profile the sRGB control
# went to the green primary and ours did not. But it does NOT escape something
# further down - two bytes of colorant change moved red by 0.0656 and white by
# 0.0205, both greener and brighter, and a no-op control confirmed the profile's
# CONTENT is the variable rather than the act of assigning one.
#
# What is still unknown is the shape and the size, and that decides the design:
#
#   small and flat        record the assigned profile, warn, move on
#   large or level-       the Companion must control which profile is assigned
#   dependent             for the duration of a run, and restore it afterwards
#
# So: a grey ramp plus the three primaries, measured under the display's own
# profile and then under one differing by exactly two bytes. A ratio that is
# constant across the ramp means a gain or a matrix; one that varies with level
# means a tone curve is involved too.
#
#   ./run-experiment-4.sh <display-id>
#   ./run-experiment-4.sh 0x00000002
#
# The display's own profile is restored on exit and on Ctrl-C.

set -u
set +m
cd "$(dirname "$0")" || exit 1

[ $# -ge 1 ] || { echo "usage: $0 <display-id>   e.g. $0 0x00000002" >&2; exit 2; }
DISPLAY_ID=$1
DWELL=12
PERMUTED=/tmp/pgen-stage2.icc
OUT="stage2.csv"

command -v spotread >/dev/null 2>&1 || { echo "spotread not found" >&2; exit 1; }
METER_PORT=$(spotread -? 2>&1 | awk "/-c listno/,/^ *-t /" \
    | grep -E "^ +[0-9]+ = " | sed -E "s/^ +([0-9]+) = '(.*)'.*/\1|\2/" \
    | grep -v "|/dev/" | head -1 | cut -d'|' -f1)
[ -n "$METER_PORT" ] || { echo "no colorimeter visible to ArgyllCMS" >&2; exit 1; }
echo "meter on port $METER_PORT"

ASSIGNED=""
cleanup() {
    pkill -f pgen-macos-hdr-probe 2>/dev/null
    [ -n "$ASSIGNED" ] && ./pgen-colorsync-probe restore "$DISPLAY_ID" >/dev/null 2>&1
    ASSIGNED=""
}
trap cleanup EXIT INT TERM

# Yxy, with the patch up. Returns "Y x y" or empty.
measure_rgb() {
    local rgb=$1 log result
    log=$(mktemp)
    ./pgen-macos-hdr-probe --display-id "$DISPLAY_ID" --sdr-ours "$rgb" \
        --dwell "$DWELL" >"$log" 2>&1 &
    local probe=$!
    sleep 3
    if ! kill -0 $probe 2>/dev/null; then
        echo "  probe exited early:" >&2; sed 's/^/    /' "$log" >&2
        rm -f "$log"; echo ""; return
    fi
    result=$(spotread -e -x -O -c "$METER_PORT" 2>&1 | grep -i "Yxy:" | tail -1 \
             | sed -E 's/.*Yxy: *([0-9.]+) +([0-9.]+) +([0-9.]+).*/\1 \2 \3/')
    # Anything the probe flagged - backlight drift, reconfiguration - invalidates
    # this reading, so surface it rather than folding it into the numbers.
    grep -E "^WARNING" "$log" | sed 's/^/    /' >&2
    kill $probe 2>/dev/null; wait $probe 2>/dev/null; rm -f "$log"
    echo "$result"
}

PATCHES="32,32,32 64,64,64 96,96,96 128,128,128 160,160,160 192,192,192 224,224,224 255,255,255 255,0,0 0,255,0 0,0,255"

echo "patch,phase,Y,x,y" > "$OUT"

run_phase() {
    local phase=$1
    echo
    echo "$phase:"
    for rgb in $PATCHES; do
        reading=$(measure_rgb "$rgb")
        if [ -z "$reading" ]; then
            printf "  %-12s no reading\n" "$rgb"
            continue
        fi
        set -- $reading
        printf "  %-12s Y %-10s x %-8s y %s\n" "$rgb" "$1" "$2" "$3"
        echo "$rgb,$phase,$1,$2,$3" >> "$OUT"
    done
}

echo "reading the display's current profile..."
ORIGINAL=$(./pgen-colorsync-probe list 2>/dev/null | awk -v id="$DISPLAY_ID" '
    $1=="display" && $2==id {found=1; next}
    found && $1=="profile" {
        line=$0
        sub(/^[[:space:]]*profile[[:space:]]+/, "", line)
        sub(/[[:space:]]+\[[a-z]+\][[:space:]]*$/, "", line)
        print line; exit }')
[ -f "$ORIGINAL" ] || { echo "no profile file for $DISPLAY_ID" >&2; exit 1; }
echo "  $ORIGINAL"

run_phase own

echo
echo "building a profile that differs by exactly two bytes..."
python3 make-permuted-profile.py build "$ORIGINAL" "$PERMUTED" --minimal || exit 1
DIFFERING=$(cmp -l "$ORIGINAL" "$PERMUTED" 2>/dev/null | wc -l | tr -d " ")
[ "${DIFFERING:-0}" = "2" ] || {
    echo "  ABORTING: $DIFFERING bytes differ, not 2 - the minimal builder did not run." >&2
    exit 1; }
echo "  verified: exactly 2 bytes differ"
./pgen-colorsync-probe assign "$DISPLAY_ID" "$PERMUTED" >/dev/null || {
    echo "assignment failed" >&2; exit 1; }
ASSIGNED=1
sleep 2

run_phase swapped
cleanup

echo
python3 - "$OUT" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
data = {}
for r in rows:
    data.setdefault(r["patch"], {})[r["phase"]] = (
        float(r["Y"]), float(r["x"]), float(r["y"]))

greys = [p for p in ("32,32,32","64,64,64","96,96,96","128,128,128",
                     "160,160,160","192,192,192","224,224,224","255,255,255")
         if p in data and len(data[p]) == 2]
prims = [p for p in ("255,0,0","0,255,0","0,0,255")
         if p in data and len(data[p]) == 2]

if not greys:
    print("  not enough paired readings to analyse."); raise SystemExit(1)

print("  grey ramp - what the two-byte colorant change did")
print(f"  {'patch':<14}{'Y own':>9}{'Y swap':>9}{'ratio':>8}{'dxy':>8}")
ratios = []
for p in greys:
    (Yo, xo, yo), (Ys, xs, ys) = data[p]["own"], data[p]["swapped"]
    ratio = Ys / Yo if Yo else 0.0
    dxy = ((xs - xo) ** 2 + (ys - yo) ** 2) ** 0.5
    ratios.append(ratio)
    print(f"  {p:<14}{Yo:>9.3f}{Ys:>9.3f}{ratio:>8.3f}{dxy:>8.4f}")

spread = (max(ratios) - min(ratios)) / (sum(ratios) / len(ratios))
print()
print(f"  luminance ratio: {min(ratios):.3f} to {max(ratios):.3f}, "
      f"spread {spread*100:.1f}% of the mean")
print()
if spread < 0.05:
    print("  FLAT. The ratio holds across the ramp, so the transform reaching our")
    print("  layer is a gain or a matrix, with no tone curve. A profile built")
    print("  under one assigned profile is convertible to another by a fixed")
    print("  factor, and recording which profile was active may be enough.")
else:
    print("  LEVEL-DEPENDENT. The ratio changes across the ramp, so a tone curve")
    print("  is involved and no single factor relates the two. The Companion must")
    print("  control which profile is assigned for the duration of a run.")

print()
print("  primaries")
for p in prims:
    (Yo, xo, yo), (Ys, xs, ys) = data[p]["own"], data[p]["swapped"]
    print(f"  {p:<12} own {xo:.4f},{yo:.4f} Y {Yo:8.3f}   "
          f"swapped {xs:.4f},{ys:.4f} Y {Ys:8.3f}")
if len(prims) == 3:
    print()
    print("  If red and green exchanged chromaticity, the colorant swap is being")
    print("  applied to our layer in full. If they only shifted, it is partial -")
    print("  and the size of that shift is the number the design turns on.")
PY
echo
echo "wrote $OUT"
