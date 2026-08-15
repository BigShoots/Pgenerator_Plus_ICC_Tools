#!/bin/bash
# Experiment 2 - does macOS put our PQ codes on the wire unchanged?
#
# This decides whether a macOS HDR path is worth building. SDL3's Metal
# renderer refuses any output colorspace but sRGB and scRGB, so PQ needs a
# bespoke CAMetalLayer the way Windows needs a bespoke DXGI swapchain - several
# hundred lines, worth writing only if macOS does not tone-map what we hand it.
#
#   ./run-experiment-2.sh --check <display-id>     verify meter and HDR, measure nothing
#   ./run-experiment-2.sh <display-id> <label>     full sweep, results to CSV
#
# Run the sweep three times, changing one thing each time:
#
#   A   SDR brightness slider at 50%          ./run-experiment-2.sh 0x1 A
#   B   slider at 100%, nothing else changed  ./run-experiment-2.sh 0x1 B
#   C   slider back to 50%, --metadata-max 600
#
# A against B is the decisive comparison. If WindowServer is tone-mapping, the
# map is a function of current EDR headroom, and headroom moves with that
# slider. A tone-mapper cannot hold A and B within 2% of each other.
#
# Before starting: enable HDR for the display, and turn off True Tone, Night
# Shift and automatic brightness. All three modulate output and none can be
# read through a public API.

set -u
# Job-control notices ("Terminated: 15") are noise here: every patch window is
# killed on purpose once its reading is taken.
set +m
cd "$(dirname "$0")" || exit 1

DWELL=12
METER_PORT=""
LAST_METER_OUTPUT=""

instrument_list() {
    spotread -? 2>&1 | awk "/-c listno/,/^ *-t /" \
        | grep -E "^ +[0-9]+ = " | sed -E "s/^ +([0-9]+) = '(.*)'.*/\1|\2/"
}

check_meter() {
    command -v spotread >/dev/null 2>&1 || {
        echo "spotread not found. brew install argyll-cms" >&2; return 1; }
    local found
    found=$(instrument_list | grep -v "|/dev/" | head -1)
    if [ -z "$found" ]; then
        echo "No colorimeter visible to ArgyllCMS - only serial ports." >&2
        echo "Plug it in directly rather than through a hub, and close any" >&2
        echo "vendor software that might be holding it open." >&2
        return 1
    fi
    METER_PORT=$(echo "$found" | cut -d'|' -f1)
    echo "meter: $(echo "$found" | cut -d'|' -f2)"
}

read_meter() {
    local out
    out=$(spotread -e -x -O -c "$METER_PORT" 2>&1)
    LAST_METER_OUTPUT=$out
    echo "$out" | grep -iE "Yxy:" | tail -1 \
        | sed -E 's/.*Yxy: *([0-9.]+) +([0-9.]+) +([0-9.]+).*/\1 \2 \3/'
}

# Show one PQ level and measure it. Refuses to return a number when the display
# is not actually presenting extended range - a reading taken at headroom 1.0
# is an SDR reading wearing an HDR label, and is worse than no reading.
measure_pq() {
    local nits=$1 extra=$2 log result headroom
    log=$(mktemp)
    ./pgen-macos-hdr-probe --display-id "$DISPLAY_ID" --hold "$nits" \
        --dwell "$DWELL" $extra >"$log" 2>&1 &
    local probe=$!
    sleep 3
    if ! kill -0 $probe 2>/dev/null; then
        echo "  probe exited early:" >&2; sed 's/^/    /' "$log" >&2
        rm -f "$log"; echo ""; return
    fi
    headroom=$(grep "EDR headroom while presenting" "$log" | sed -E 's/.*: ([0-9.]+) .*/\1/')
    result=$(read_meter)
    kill $probe 2>/dev/null; wait $probe 2>/dev/null

    if [ -n "$headroom" ] && [ "$(echo "$headroom <= 1.0" | bc -l 2>/dev/null)" = "1" ]; then
        echo "  HEADROOM 1.0 - not presenting extended range" >&2
        rm -f "$log"; echo ""; return
    fi
    rm -f "$log"
    [ -z "$result" ] && { echo "  no reading:" >&2
                          echo "$LAST_METER_OUTPUT" | sed 's/^/    /' >&2; }
    echo "$result"
}

# ------------------------------------------------------------------ check

if [ $# -ge 2 ] && [ "$1" = "--check" ]; then
    DISPLAY_ID=$2
    # Report both independently. HDR readiness is the more likely blocker and
    # does not need a meter, so gating it behind one hides the answer.
    check_meter || echo "  (meter unavailable - the HDR check below still works)"
    echo
    echo "bringing up a 100-nit PQ patch to see whether the display grants"
    echo "extended range..."
    log=$(mktemp)
    ./pgen-macos-hdr-probe --display-id "$DISPLAY_ID" --hold 100 --dwell 6 \
        >"$log" 2>&1 &
    sleep 4
    grep -E "^display |^probe build|^on screen|EDR headroom while|^WARNING" "$log" \
        | sed 's/^/  /'
    pkill -f pgen-macos-hdr-probe 2>/dev/null
    headroom=$(grep "EDR headroom while presenting" "$log" | sed -E 's/.*: ([0-9.]+) .*/\1/')
    rm -f "$log"
    echo
    if [ -z "$headroom" ]; then
        echo "  could not read the headroom - see above."
    elif [ "$(echo "$headroom <= 1.0" | bc -l 2>/dev/null)" = "1" ]; then
        cat <<'MSG'
  NOT READY. The display is not presenting extended range, so every reading
  would be an SDR reading with an HDR label on it.

  Try, in order:
    - System Settings > Displays: enable HDR for this display
    - on a built-in XDR panel, choose a preset that supports HDR
      (Apple XDR Display presets, or HDR Video P3-ST 2084)
    - check the display is not mirroring another
MSG
    else
        echo "  READY. Headroom $headroom. Run the sweep."
    fi
    exit 0
fi

# ------------------------------------------------------------------ sweep

if [ $# -lt 2 ]; then
    echo "usage: $0 <display-id> <label>     e.g. $0 0x00000001 A" >&2
    echo "       $0 --check <display-id>" >&2
    exit 2
fi

DISPLAY_ID=$1
LABEL=$2
EXTRA=""
shift 2
[ $# -gt 0 ] && EXTRA="$*"

check_meter || exit 1
OUT="pq-sweep-$LABEL.csv"
echo "target_nits,code,measured_Y,x,y" > "$OUT"

echo
echo "sweep $LABEL${EXTRA:+  ($EXTRA)}  ->  $OUT"
echo "keep the meter still and the room dark. Ctrl-C to stop."
echo
printf "  %-8s %-6s %-10s %s\n" target code measured ratio

FAILED=0
for nits in 0.1 1 5 10 50 100 203 400 600 1000; do
    reading=$(measure_pq "$nits" "$EXTRA")
    if [ -z "$reading" ]; then
        FAILED=$((FAILED + 1))
        [ "$FAILED" -ge 2 ] && { echo "  two failures - stopping." >&2; break; }
        continue
    fi
    set -- $reading
    Y=$1; x=$2; y=$3
    ratio=$(python3 -c "print(f'{$Y/$nits:.2f}')" 2>/dev/null)
    code=$(python3 -c "
import math
m1,m2=2610/16384,2523/4096*128
c1,c2,c3=3424/4096,2413/4096*32,2392/4096*32
Y=$nits/10000.0
ym=Y**m1
print(round(((c1+c2*ym)/(1+c3*ym))**m2*1023))")
    printf "  %-8s %-6s %-10s %s\n" "$nits" "$code" "$Y" "$ratio"
    echo "$nits,$code,$Y,$x,$y" >> "$OUT"
done

echo
echo "wrote $OUT"
echo "Run this again with the brightness slider moved, then compare:"
echo "  paste -d, pq-sweep-A.csv pq-sweep-B.csv"
echo "A measured column that tracks the target is passthrough. One that"
echo "compresses smoothly below the panel's peak is tone mapping. If A and B"
echo "differ by more than 2%, it is tone mapping regardless of shape."
