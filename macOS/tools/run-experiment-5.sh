#!/bin/bash
# Experiment 5 - does the clut correction mode round-trip on macOS?
#
# Upstream's macOS README says "macOS still composites through the assigned
# profile" and enables the clut and matrix modes on that basis. Those modes
# apply the assigned profile's INVERSE inside the Companion, on the assumption
# the compositor then applies the forward transform, so the pair cancels. That
# is exactly how it works on Windows and KWin.
#
# Spike A measured something different for SDR here: under a profile whose red
# and green colorants were swapped, an sRGB-tagged control layer went fully to
# the green primary while the Companion's own nil-colorspace layer moved about
# 16% of the way. If the forward transform is not being applied to our layer,
# the inverse has nothing to cancel against.
#
# This settles it with one observation, using a deliberately wrong profile so
# the answer cannot be subtle:
#
#   assign a profile with red and green colorants swapped, then ask for RED
#
#     system mode  the Companion sends red device values. Whatever macOS does,
#                  this is the baseline.
#     clut mode    the Companion works out which device values produce "red"
#                  through the swapped profile - which is to drive the GREEN
#                  channel - and sends those.
#
#   measures RED   the round trip closes: macOS applied the forward transform,
#                  clut is correct, and our refusal is too strict.
#   measures GREEN the inverse was applied with nothing to cancel it. clut
#                  produces wrong profiles on macOS, in the shipped build.
#
# Grey would prove nothing: a neutral is invariant under a red/green swap.
#
#   ./run-experiment-5.sh <display-id> [path to a Companion binary]
#   ./run-experiment-5.sh 0x00000002
#
# Defaults to upstream's shipped build in ./upstream/ if present, because what
# matters is the behaviour of what people actually download.

set -u
set +m
cd "$(dirname "$0")" || exit 1

[ $# -ge 1 ] || { echo "usage: $0 <display-id> [companion binary]" >&2; exit 2; }
DISPLAY_ID=$1
COMPANION=${2:-}
PORT=8098
PERMUTED=/tmp/pgen-clut.icc

if [ -z "$COMPANION" ]; then
    for candidate in "upstream/PGenerator+ ICC Tools/PGenPatchCompanion" \
                     "apps/PGeneratorPlusPatchCompanion.app/Contents/MacOS/PGeneratorPlusPatchCompanion"; do
        [ -x "$candidate" ] && { COMPANION=$candidate; break; }
    done
fi
[ -n "$COMPANION" ] && [ -x "$COMPANION" ] || {
    echo "no Companion binary found. Put upstream's release in ./upstream/ or" >&2
    echo "pass a path as the second argument." >&2; exit 1; }
echo "testing: $COMPANION"

command -v spotread >/dev/null 2>&1 || { echo "spotread not found" >&2; exit 1; }
METER_PORT=$(spotread -? 2>&1 | awk "/-c listno/,/^ *-t /" \
    | grep -E "^ +[0-9]+ = " | sed -E "s/^ +([0-9]+) = '(.*)'.*/\1|\2/" \
    | grep -v "|/dev/" | head -1 | cut -d'|' -f1)
[ -n "$METER_PORT" ] || { echo "no colorimeter visible to ArgyllCMS" >&2; exit 1; }

ASSIGNED=""
cleanup() {
    pkill -f PGenPatchCompanion 2>/dev/null
    pkill -f PGeneratorPlusPatchCompanion 2>/dev/null
    pkill -f "mock-pgen-server.py --port $PORT" 2>/dev/null
    [ -n "$ASSIGNED" ] && ./pgen-colorsync-probe restore "$DISPLAY_ID" >/dev/null 2>&1
    ASSIGNED=""
}
trap cleanup EXIT INT TERM

ORIGINAL=$(./pgen-colorsync-probe list 2>/dev/null | awk -v id="$DISPLAY_ID" '
    $1=="display" && $2==id {found=1; next}
    found && $1=="profile" {
        line=$0
        sub(/^[[:space:]]*profile[[:space:]]+/, "", line)
        sub(/[[:space:]]+\[[a-z]+\][[:space:]]*$/, "", line)
        print line; exit }')
[ -f "$ORIGINAL" ] || { echo "no profile file for $DISPLAY_ID" >&2; exit 1; }
DISPLAY_NAME=$(./pgen-colorsync-probe list 2>/dev/null | awk -v id="$DISPLAY_ID" \
    '$1=="display" && $2==id {$1="";$2=""; sub(/^ +/,""); print; exit}')
echo "display: $DISPLAY_NAME"

echo "building the swapped profile..."
python3 make-permuted-profile.py build "$ORIGINAL" "$PERMUTED" --minimal || exit 1
DIFFERING=$(cmp -l "$ORIGINAL" "$PERMUTED" 2>/dev/null | wc -l | tr -d " ")
[ "${DIFFERING:-0}" = "2" ] || { echo "  ABORTING: $DIFFERING bytes differ, not 2" >&2; exit 1; }
echo "  verified: exactly 2 bytes differ"

# clut evaluates a B2A0 cLUT. Apple's display profiles are matrix/TRC and have
# none, so clut legitimately fails on them - which is what the first two runs of
# this script actually recorded. matrix uses rXYZ/gXYZ/bXYZ plus the tone
# curves, which is exactly what a colorant swap changes, so that is the mode
# that tests the round trip here.
HAS_CLUT=$(python3 make-permuted-profile.py inspect "$ORIGINAL" 2>/dev/null | grep -c "B2A0")
if [ "${HAS_CLUT:-0}" = "0" ]; then
    echo "  this profile is matrix/TRC with no B2A0 cLUT, so clut cannot apply;"
    echo "  testing matrix, which is what a colorant swap exercises."
    MODES="matrix clut"
else
    MODES="clut matrix"
fi

./pgen-colorsync-probe assign "$DISPLAY_ID" "$PERMUTED" >/dev/null || {
    echo "assignment failed" >&2; exit 1; }
ASSIGNED=1
sleep 2

# A stale conf sends the Companion to whatever it paired with last.
rm -f "$(dirname "$COMPANION")/PGenPatchCompanion.conf"
rm -rf ~/Library/Application\ Support/PGeneratorPlus

python3 mock-pgen-server.py --port "$PORT" --no-console >/tmp/pgen-clut-mock.log 2>&1 &
sleep 2
"$COMPANION" --server="http://127.0.0.1:$PORT" --display="$DISPLAY_NAME" \
    >/tmp/pgen-clut-companion.log 2>&1 &
sleep 10

measure_mode() {
    local mode=$1 reading
    curl -s "http://127.0.0.1:$PORT/mock/settings?correction_mode=$mode" >/dev/null
    sleep 3
    curl -s "http://127.0.0.1:$PORT/mock/patch?r=255&g=0&b=0" >/dev/null
    sleep 4
    reading=$(spotread -e -x -O -c "$METER_PORT" 2>&1 | grep -i "Yxy:" | tail -1 \
              | sed -E 's/.*Yxy: *([0-9.]+) +([0-9.]+) +([0-9.]+).*/\1 \2 \3/')
    local state
    state=$(curl -s "http://127.0.0.1:$PORT/mock/state" | python3 -c "
import json,sys
d=json.load(sys.stdin); c=d.get('client') or {}; a=d.get('last_ack') or {}
note=(a.get('message') or c.get('transform_note') or '').replace('|',' ')
print(f\"{c.get('transform','')} ready={c.get('transform_ready')} ack={a.get('status','')} {note[:110]}\")" 2>/dev/null)
    echo "$reading|$state"
}

echo
echo "asking for RED with the swapped profile assigned:"
SYS=$(measure_mode system)
echo "  system : ${SYS%%|*}"
echo "           [${SYS#*|}]"
CLUT=""
for mode in $MODES; do
    RESULT=$(measure_mode "$mode")
    printf "  %-7s: %s\n" "$mode" "${RESULT%%|*}"
    echo "           [${RESULT#*|}]"
    case "${RESULT#*|}" in
        *ack=ok*) [ -z "$CLUT" ] && CLUT=$RESULT ;;
    esac
done
[ -n "$CLUT" ] || CLUT="|no mode was accepted"

echo
echo "what the Companion said about clut:"
grep -iE "correction|clut|profile|macOS:" /tmp/pgen-clut-companion.log 2>/dev/null \
    | tail -4 | sed 's/^/  /'

cleanup

python3 - "${SYS%%|*}" "${CLUT%%|*}" <<'PY'
import sys
def parse(t):
    p = t.split()
    return [float(v) for v in p] if len(p) == 3 else None
sysr, clut = parse(sys.argv[1]), parse(sys.argv[2])
print()
if not sysr:
    print("  no system reading - nothing to compare against."); raise SystemExit(1)
print(f"  system  Y {sysr[0]:8.3f}  x {sysr[1]:.4f}  y {sysr[2]:.4f}")
if not clut:
    print("  Neither correction mode was accepted, so there is nothing to")
    print("  compare. The bracketed lines above carry the Companion's reason.")
    raise SystemExit(0)
print(f"  clut    Y {clut[0]:8.3f}  x {clut[1]:.4f}  y {clut[2]:.4f}")
print()
# If the two readings are the same to within meter noise, the second patch never
# reached the screen and both numbers describe the first one. Judging a round
# trip from that is how this script reported a confident wrong answer once.
same = (abs(clut[1]-sysr[1])**2 + abs(clut[2]-sysr[2])**2) ** 0.5
if same < 0.005:
    print(f"  NO SECOND PATCH. The two readings differ by {same:.4f} in xy, which")
    print("  is meter noise - the clut patch never appeared and both numbers")
    print("  describe the system one. Check the ack line above: if it says")
    print("  ack=error, the Companion rejected the mode and that rejection, not")
    print("  these numbers, is the result.")
    raise SystemExit(0)
# Red primary sits near x 0.64; green near x 0.30, y 0.60. Nothing else is close.
if clut[1] > 0.5:
    print("  ROUND TRIP CLOSES. clut still measured red, so macOS did apply the")
    print("  forward transform and the inverse cancelled against it. The mode is")
    print("  correct on macOS and our refusal is too strict - remove it.")
elif clut[2] > 0.5:
    print("  ROUND TRIP FAILS. clut measured GREEN: the Companion applied the")
    print("  profile's inverse and nothing cancelled it, so the patch went out")
    print("  driving the wrong channel. On this build clut produces wrong")
    print("  profiles on macOS, and the refusal is right.")
else:
    print("  INCONCLUSIVE - neither a red nor a green primary. Check that the")
    print("  meter is on the patch and that the swapped profile was assigned.")
PY
