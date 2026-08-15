#!/bin/bash
# Experiment 2 - does macOS put our PQ codes on the wire unchanged?
#
# This decides whether a macOS HDR path is worth building. SDL3's Metal
# renderer refuses any output colorspace but sRGB and scRGB, so PQ needs a
# bespoke CAMetalLayer the way Windows needs a bespoke DXGI swapchain - several
# hundred lines, worth writing only if macOS does not tone-map what we hand it.
#
#   ./run-experiment-2.sh --check <display-id>     verify meter and HDR, measure nothing
#   ./run-experiment-2.sh <display-id> <label>     PQ sweep, results to CSV
#   ./run-experiment-2.sh --scrgb <id> <label>     extended-linear sweep
#   ./run-experiment-2.sh --scrgb-color <id> <lbl> channel additivity
#   ./run-experiment-2.sh --ceiling <id>           find the full-field limit
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

# ------------------------------------------------------------- scRGB sweep
#
# The path Apple actually intends for EDR, and the one the PQ sweeps never
# tested. Extended linear sRGB, float pixels, NO EDR metadata - which
# CAMetalLayer documents as "samples will be rendered without tone mapping".
#
# 1.0 is SDR white by definition. The question is whether measured luminance is
# LINEAR in the value: if measured(v)/measured(1.0) == v across the range, then
# absolute luminance is addressable by measuring SDR white once, and PQ never
# needs to be involved. Run it at two brightness settings - the absolute values
# will move because SDR white moves, but the normalised curve must not.
if [ $# -ge 3 ] && [ "$1" = "--scrgb" ]; then
    DISPLAY_ID=$2
    LABEL=$3
    check_meter || exit 1
    OUT="scrgb-sweep-$LABEL.csv"
    echo "value,measured_Y,x,y" > "$OUT"
    echo
    echo "scRGB sweep $LABEL  ->  $OUT"
    printf "  %-8s %-12s %s\n" value measured "ratio to 1.0"
    REF=""
    for v in 0.125 0.25 0.5 1.0 1.5 2.0; do
        log=$(mktemp)
        ./pgen-macos-hdr-probe --display-id "$DISPLAY_ID" --scrgb "$v" \
            --dwell "$DWELL" >"$log" 2>&1 &
        probe=$!
        sleep 3
        if ! kill -0 $probe 2>/dev/null; then
            echo "  probe exited early:" >&2; sed 's/^/    /' "$log" >&2
            rm -f "$log"; continue
        fi
        head=$(grep "EDR headroom while presenting" "$log" | sed -E 's/.*: ([0-9.]+) .*/\1/')
        reading=$(read_meter)
        kill $probe 2>/dev/null; wait $probe 2>/dev/null
        rm -f "$log"
        [ -z "$reading" ] && { echo "  $v: no reading" >&2; continue; }
        set -- $reading
        Y=$1; x=$2; y=$3
        [ "$v" = "1.0" ] && REF=$Y
        if [ -n "$REF" ]; then
            ratio=$(python3 -c "print(f'{$Y/$REF:.3f}')")
        else
            ratio="-"
        fi
        printf "  %-8s %-12s %s\n" "$v" "$Y" "$ratio"
        echo "$v,$Y,$x,$y" >> "$OUT"
        HEADROOM=$head
    done
    BACKLIGHT=$(./pgen-macos-hdr-probe --display-id "$DISPLAY_ID" --scrgb 0 --dwell 1 2>/dev/null \
                | sed -n 's/^backlight *\([0-9.]*\) .*/\1/p' | head -1)
    echo
    echo "headroom during the sweep: ${HEADROOM:-unknown}"
    if [ -n "$BACKLIGHT" ]; then
        echo "backlight target (IORegistry): $BACKLIGHT cd/m2"
        echo "  Recorded only. Measured 2026-08-15 to track neither SDR white"
        echo "  nor panel peak, and to report the same figure on two different"
        echo "  Macs - so it is NOT the scRGB conversion factor."
    fi
    echo "wrote $OUT"
    python3 - "$OUT" <<'SPY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
ref = next((float(r["measured_Y"]) for r in rows if r["value"] == "1.0"), None)
print()
if not ref:
    print("  no 1.0 reading, cannot normalise."); raise SystemExit
print("  value   measured   measured/SDRwhite   expected   error")
worst = 0.0
for r in rows:
    v, Y = float(r["value"]), float(r["measured_Y"])
    got = Y / ref
    err = abs(got - v) / v
    if v <= 1.0:
        worst = max(worst, err)
    print(f"  {v:<7} {Y:<10.3f} {got:<19.3f} {v:<10} {err*100:>5.1f}%")
print()
print(f"  worst error at or below SDR white: {worst*100:.1f}%")
if worst < 0.05:
    print("  LINEAR below SDR white. Absolute luminance is addressable by")
    print("  measuring SDR white once - no PQ, no tone mapper. Check the")
    print("  above-1.0 rows against the headroom before trusting them.")
else:
    print("  NOT LINEAR even below SDR white, so this path is no better than PQ.")
SPY
    exit 0
fi

# ------------------------------------------------------- additivity + ceiling
#
# Two things the grey sweep could not answer.
#
# ADDITIVITY. An ICC matrix profile assumes the channels are independent and
# sum: measured XYZ(R) + XYZ(G) + XYZ(B) should equal XYZ(white) at the same
# level. If they do, the extended-linear path behaves like a display and can be
# profiled. If they do not, something is cross-coupling the channels.
#
# CEILING. Reported headroom overstates what a FULL-FIELD patch can reach - on
# the M5, 2.667 headroom implied 1683 cd/m2 while full-field white topped out
# near 678. A run has to know where the real limit is, because every value
# above it measures the same and would silently flatten a profile.
if [ $# -ge 3 ] && [ "$1" = "--scrgb-color" ]; then
    DISPLAY_ID=$2
    LABEL=$3
    check_meter || exit 1
    OUT="scrgb-color-$LABEL.csv"
    echo "patch,value,Y,x,y,X,Z" > "$OUT"
    echo
    echo "additivity check at 0.5 and 1.0  ->  $OUT"
    for level in 0.5 1.0; do
        echo
        echo "level $level:"
        for patch in "white:$level,$level,$level" "red:$level,0,0" \
                     "green:0,$level,0" "blue:0,0,$level"; do
            name=${patch%%:*}; rgb=${patch#*:}
            log=$(mktemp)
            ./pgen-macos-hdr-probe --display-id "$DISPLAY_ID" --scrgb-rgb "$rgb" \
                --dwell "$DWELL" >"$log" 2>&1 &
            probe=$!
            sleep 3
            kill -0 $probe 2>/dev/null || { echo "  $name: probe died" >&2
                                            sed 's/^/    /' "$log" >&2
                                            rm -f "$log"; continue; }
            reading=$(read_meter)
            grep -E "^WARNING" "$log" | sed 's/^/    /' >&2
            kill $probe 2>/dev/null; wait $probe 2>/dev/null; rm -f "$log"
            [ -z "$reading" ] && { echo "  $name: no reading" >&2; continue; }
            set -- $reading
            # Yxy -> XYZ, so the three channels can be summed.
            read X Z <<<"$(python3 -c "
Y,x,y=$1,$2,$3
print(f'{x*Y/y:.6f} {(1-x-y)*Y/y:.6f}')")"
            printf "  %-6s Y %-10s x %-8s y %s\n" "$name" "$1" "$2" "$3"
            echo "$name,$level,$1,$2,$3,$X,$Z" >> "$OUT"
        done
    done
    echo
    python3 - "$OUT" <<'APY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
for level in sorted({r["value"] for r in rows}):
    at = {r["patch"]: r for r in rows if r["value"] == level}
    if not all(k in at for k in ("white", "red", "green", "blue")):
        print(f"  level {level}: incomplete"); continue
    def xyz(p): return tuple(float(at[p][k]) for k in ("X", "Y", "Z"))
    w = xyz("white")
    s = tuple(sum(xyz(p)[i] for p in ("red", "green", "blue")) for i in range(3))
    err = max(abs(s[i] - w[i]) / w[i] for i in range(3) if w[i])
    print(f"  level {level}:  white XYZ {w[0]:.2f} {w[1]:.2f} {w[2]:.2f}")
    print(f"            R+G+B XYZ {s[0]:.2f} {s[1]:.2f} {s[2]:.2f}   worst {err*100:.1f}%")
    print("            " + ("ADDITIVE - behaves like a display, profilable"
                            if err < 0.05 else
                            "NOT ADDITIVE - channels are cross-coupling"))
APY
    exit 0
fi

if [ $# -ge 2 ] && [ "$1" = "--ceiling" ]; then
    DISPLAY_ID=$2
    check_meter || exit 1
    echo
    echo "climbing until full-field output stops rising:"
    printf "  %-8s %-12s %s\n" value measured "vs previous"
    PREV=""
    for v in 1.0 1.25 1.5 1.75 2.0 2.5 3.0 4.0; do
        log=$(mktemp)
        ./pgen-macos-hdr-probe --display-id "$DISPLAY_ID" --scrgb "$v" \
            --dwell "$DWELL" >"$log" 2>&1 &
        probe=$!
        sleep 3
        kill -0 $probe 2>/dev/null || { rm -f "$log"; break; }
        reading=$(read_meter)
        kill $probe 2>/dev/null; wait $probe 2>/dev/null; rm -f "$log"
        [ -z "$reading" ] && break
        set -- $reading
        if [ -n "$PREV" ]; then
            gain=$(python3 -c "print(f'{$1/$PREV:.3f}')")
        else
            gain="-"
        fi
        printf "  %-8s %-12s %s\n" "$v" "$1" "$gain"
        if [ -n "$PREV" ] && [ "$(python3 -c "print(1 if $1/$PREV < 1.02 else 0)")" = "1" ]; then
            echo
            echo "  CEILING near $1 cd/m2 - output stopped rising at value $v."
            echo "  Patches above that measure the same and would flatten the top"
            echo "  of a profile. Cap HDR targets here, not at the reported headroom."
            break
        fi
        PREV=$1
    done
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
